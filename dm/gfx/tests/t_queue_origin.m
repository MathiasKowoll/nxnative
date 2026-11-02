// NVN's queue initialization captures WINDOW_ORIGIN.FLIP_Y. The device origin
// used to construct later viewports can change independently. Check actual
// culling and front_facing pixels while alternating two queues on one device.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
#define P(name) ((NVNT_##name)nvn_lookup(#name))
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, label) do { checks++; if (!(c)) { fails++; fprintf(stderr,"FAIL: %s\n",label); } } while (0)
static uint8_t commands[8192]; static size_t used;
static void emit(unsigned op, const void *p, size_t n) {
    size_t size = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)size};
    memcpy(commands + used, &h, 8); if (n) memcpy(commands + used + 8, p, n); used += size;
}
int main(void) { @autoreleasepool {
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct I { float4 p [[attribute(0)]]; };\n"
        "vertex float4 v(I i [[stage_in]]) { return i.p; }\n"
        "fragment float4 f(bool front [[front_facing]]) { return front ? float4(0,1,0,1) : float4(1,0,0,1); }\n"
        options:nil error:&error];
    CHECK(library != nil,"test shaders compile"); if (!library) return 1;
    static prog_t pg = {.serial=920001}; NvProg *program = [NvProg new];
    NvShader *vs = [NvShader new]; vs->fn = [library newFunctionWithName:@"v"];
    vs->rf.nv = 1; vs->rf.v[0].ct = NVN_CT_FLOAT;
    memset(vs->rf.v[0].sh,0xff,sizeof vs->rf.v[0].sh);
    vs->rf.pos_attr = 0; vs->rf.pos_w1 = 1; program->sh[0] = vs;
    NvShader *fs = [NvShader new]; fs->fn = [library newFunctionWithName:@"f"];
    fs->stage = 1; fs->rf.color_mask = 1; program->sh[1] = fs; serial_put(pg.serial,program);
    tex_t target = {.magic=MAGIC('T','E','X',0),.serial=920002};
    target.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=8,.depth=1,.levels=1,.samples=1};
    void *vertices = NULL; CHECK(!posix_memalign(&vertices,getpagesize(),65536),"vertex storage allocated");
    if (!vertices) return 1; memset(vertices,0,65536); mtl_pool_add(vertices,65536);
    static NVNdevice device; static NVNqueue queues[2]; NVNdeviceBuilder db = {0};
    P(nvnDeviceBuilderSetDefaults)(&db); CHECK(P(nvnDeviceInitialize)(&device,&db),"device initialized");
    for (int origin=0;origin<2;origin++) {
        P(nvnDeviceSetWindowOriginMode)(&device,(NVNwindowOriginMode)origin);
        NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb,&device);
        if (origin) {
            void (*set_primary)(NVNqueueBuilder *, NVNqueue *) = nvn_lookup("nvnQueueBuilderSetPrimaryQueue");
            CHECK(set_primary != NULL,"NVN2 primary-queue entry is exposed");
            if (!set_primary) return 1;
            set_primary(&qb,&queues[0]);
        }
        CHECK(P(nvnQueueInitialize)(&queues[origin],&qb),"queue initialized");
    }
    CHECK(((queue_t *)&queues[1])->primary_serial == ((queue_t *)&queues[0])->serial,
          "secondary queue retains primary identity");
    CHECK(((queue_t *)&queues[1])->serial != ((queue_t *)&queues[0])->serial,
          "secondary queue has independent replay state");
    NVNqueueBuilder invalid = {0}; NVNqueue rejected = {0}; NVNdevice other = {0};
    P(nvnQueueBuilderSetDefaults)(&invalid); P(nvnQueueBuilderSetDevice)(&invalid,&other);
    h_nvnQueueBuilderSetPrimaryQueue(&invalid,&queues[0]);
    CHECK(!P(nvnQueueInitialize)(&rejected,&invalid),"cross-device primary is rejected");
    h_nvnQueueBuilderSetPrimaryQueue(&invalid,&rejected);
    CHECK(!P(nvnQueueInitialize)(&rejected,&invalid),"self-primary is rejected");
    P(nvnQueueBuilderSetDefaults)(&invalid);
    CHECK(!QB(&invalid)->primary,"defaults clear primary association");
    struct { program_builder_t builder; uint64_t canary; } pb = {.canary=0x123456789abcdef0};
    h_nvnProgramBuilderSetDevice(&pb.builder,&device);
    h_nvnProgramBuilderSetDefaults(&pb.builder);
    CHECK(h_nvnProgramBuilderGetDevice(&pb.builder)==&device && !h_nvnProgramBuilderGetShaderCount(&pb.builder),
          "program defaults preserve device and clear stages");
    CHECK(pb.canary==0x123456789abcdef0,"program builder stays in its allocation");
    uint8_t control[0xd8]={0}; uint32_t fields[][2]={{0,0x98761234},{4,201},{8,7},{0x30,0xd8},{0x40,0x100}};
    for (unsigned i=0;i<sizeof fields/sizeof *fields;i++) memcpy(control+fields[i][0],&fields[i][1],4);
    uint8_t code[0x100]={0}; NVNshaderData data={(uint64_t)code,control}; NVNprogram built={0};
    h_nvnProgramBuilderSetShaders(&pb.builder,1,&data);
    CHECK(h_nvnProgramBuilderGetShaders(&pb.builder)==&data,"builder retains shader descriptors");
    CHECK(h_nvnProgramInitializeFromBuilder(&built,&pb.builder),"compact shader program initializes");
    uint8_t key[8], expected[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash); CC_SHA256_Update(&hash,control,sizeof control); CC_SHA256_Update(&hash,code,sizeof code); CC_SHA256_Final(expected,&hash);
    CHECK(prog_key((prog_t *)&built,0,key) && !memcmp(key,expected,sizeof key),"NVN2 key hashes exactly its control and code spans");
    CHECK(prog_stage((prog_t *)&built,0)==0,"NVN2 compact control reports vertex stage zero");
    memcpy(control+0x54,(uint32_t[]){6u<<16},4);
    CHECK(h_nvnProgramSetShaders(&built,1,&data),"NVN2 task-stage program initializes");
    CHECK(prog_stage((prog_t *)&built,0)==6,"NVN2 compact control reports task/object stage six");
    memcpy(control+0x54,(uint32_t[]){7u<<16},4);
    CHECK(h_nvnProgramSetShaders(&built,1,&data),"NVN2 mesh-stage program initializes");
    CHECK(prog_stage((prog_t *)&built,0)==7,"NVN2 compact control reports mesh stage seven");
    memset(control+0x54,0,4);
    memcpy(control+0xc4,(uint32_t[]){0xd8},4); memset(control+0x30,0,4);
    CHECK(h_nvnProgramSetShaders(&built,1,&data),"runtime compact shader control initializes from its secondary size");
    CC_SHA256_Init(&hash); CC_SHA256_Update(&hash,control,sizeof control); CC_SHA256_Update(&hash,code,sizeof code); CC_SHA256_Final(expected,&hash);
    CHECK(prog_key((prog_t *)&built,0,key) && !memcmp(key,expected,sizeof key),"runtime compact control hashes its exact 216-byte span");
    h_nvnProgramFinalize(&built);
    h_nvnProgramBuilderSetShaders(&pb.builder,7,&data);
    CHECK(!h_nvnProgramInitializeFromBuilder(&built,&pb.builder),"oversized shader list is rejected");
    h_nvnProgramBuilderSetShaders(&pb.builder,1,NULL);
    CHECK(!h_nvnProgramInitializeFromBuilder(&built,&pb.builder),"missing shader descriptors are rejected");
    // Task/object and mesh resources must survive state replay even though the
    // dedicated Metal argument encoder is not connected yet.
    for (int stage=6;stage<=7;stage++) {
        p_bind_buf ub={stage,3,0x1000u+(uint64_t)stage,64}, sb={stage,4,0x2000u+(uint64_t)stage,128};
        p_bind_handles tx={.stage=stage,.first=5,.n=1,.h={0x12345}},
                       sm={.stage=stage,.first=6,.n=1,.h={0x23456}},
                       im={.stage=stage,.first=7,.n=1,.h={0x34567}};
        state_op(OP_BIND_UBO,&ub); state_op(OP_BIND_SSBO,&sb);
        state_op(OP_BIND_TEX,&tx); state_op(OP_BIND_SAMP,&sm); state_op(OP_BIND_IMG,&im);
        CHECK(S.ubo[stage][3].addr==ub.addr && S.ssbo[stage][4].addr==sb.addr,
              stage==6 ? "task/object buffer bindings are retained" : "mesh buffer bindings are retained");
        CHECK(S.tex[stage][5]==tx.h[0] && S.samp[stage][6]==sm.h[0] && S.img[stage][7]==im.h[0],
              stage==6 ? "task/object descriptor bindings are retained" : "mesh descriptor bindings are retained");
    }
    // A mesh-task command must survive recording as a replay operation. The
    // Metal backend remains an explicit stop until its object/mesh translation
    // exists, but recording and capture may no longer abort first.
    {
        NVNcommandBuffer cb={0}; uint8_t mem[256]; pool_t pool={.mem=mem,.size=sizeof mem};
        prog_t meshpg={.magic=MAGIC('P','R','O','G'),.nstage=3,.serial=1234};
        CHECK(P(nvnCommandBufferInitialize)(&cb,&device),"mesh command buffer initializes");
        P(nvnCommandBufferAddCommandMemory)(&cb,(NVNmemoryPool *)&pool,0,sizeof mem);
        P(nvnCommandBufferBeginRecording)(&cb);
        h_nvnCommandBufferBindProgram(&cb,(NVNprogram *)&meshpg,0xff);
        h_nvnCommandBufferSetGeometryProcessingMode(&cb,1);
        h_nvnCommandBufferDrawMeshTasks(&cb,7,11);
        NVNcommandHandle handle=P(nvnCommandBufferEndRecording)(&cb);
        op_hdr bh, mh; memcpy(&bh,(const void *)handle,sizeof bh); memcpy(&mh,(const uint8_t *)handle+bh.size,sizeof mh);
        const p_draw_mesh *md=(const p_draw_mesh *)((const uint8_t *)handle+bh.size+sizeof mh);
        CHECK(bh.op==OP_BIND_PROGRAM && mh.op==OP_DRAW_MESH,"mesh-task draw is recorded for replay");
        CHECK(mh.size==32 && md->prog==&meshpg && md->stages==0xff && md->mode==1 && md->first==7 && md->count==11,
              "mesh-task replay record preserves program, mode and range");
        P(nvnCommandBufferFinalize)(&cb);
    }
    // NVN2 graphics constants are copied into a compact command record and
    // retained as one of the eight 256-byte root tables at replay.
    {
        NVNcommandBuffer cb={0}; uint8_t mem[256], values[16]; pool_t pool={.mem=mem,.size=sizeof mem};
        for (int i=0;i<16;i++) values[i]=(uint8_t)(0xa0+i);
        CHECK(P(nvnCommandBufferInitialize)(&cb,&device),"root-table command buffer initializes");
        P(nvnCommandBufferAddCommandMemory)(&cb,(NVNmemoryPool *)&pool,0,sizeof mem);
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferPushGraphicsConstants)(&cb,3,12,16,values);
        NVNcommandHandle handle=P(nvnCommandBufferEndRecording)(&cb);
        memset(values,0,sizeof values);
        op_hdr h; memcpy(&h,(const void *)handle,sizeof h);
        const p_push_gfx_const *pc=(const p_push_gfx_const *)((const uint8_t *)handle+sizeof h);
        CHECK(h.op==OP_PUSH_GFX_CONST && h.size==32,"graphics constants use a bounded inline record");
        CHECK(pc->table==3 && pc->offset==12 && pc->size==16 && pc->data[0]==0xa0 && pc->data[15]==0xaf,
              "graphics constants record owns its data");
        memset(S.root,0,sizeof S.root); state_op(h.op,pc);
        CHECK(!memcmp(S.root[3]+12,(uint8_t[]){0xa0,0xa1,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xab,0xac,0xad,0xae,0xaf},16),
              "graphics constants update the selected root-table range");
        CHECK(S.root[3][11]==0 && S.root[3][28]==0,"graphics constants preserve bytes outside the range");
        P(nvnCommandBufferFinalize)(&cb);
    }
    // Both NVN2 recording forms must defer copies until submission and fence
    // the copied bytes. The same check runs on the independent secondary queue.
    for (int mode=0;mode<2;mode++) {
        NVNcommandBuffer cb={0}; NVNsync fence={0}; uint8_t mem[512];
        pool_t pool={.mem=mem,.size=sizeof mem};
        uint8_t *src=vertices, *dst=src+32768;
        memset(src,0x5a+mode,1024); memset(dst,0,1024);
        CHECK(P(nvnCommandBufferInitialize)(&cb,&device),"command buffer initializes");
        CHECK(P(nvnSyncInitialize)(&fence,&device),"recorded fence initializes");
        h_nvnCommandBufferSetRecordingMode(&cb,mode);
        P(nvnCommandBufferAddCommandMemory)(&cb,(NVNmemoryPool *)&pool,0,sizeof mem);
        P(nvnCommandBufferBeginRecording)(&cb);
        h_nvnCommandBufferSetComputeOverlapMode(&cb,mode);
        h_nvnCommandBufferBindShadingRateImage(&cb,NULL,NULL);
        tex_t rate={.magic=MAGIC('T','E','X',0)}; rate.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_R8UI,.width=160,.height=90,.depth=1,.levels=1};
        h_nvnCommandBufferBindShadingRateImage(&cb,(NVNtexture *)&rate,NULL);
        h_nvnCommandBufferShadingRateImagePalette(&cb,0,0,NULL);
        int rates[16]; for (int i=0;i<16;i++) rates[i]=i;
        h_nvnCommandBufferShadingRateImagePalette(&cb,1,16,rates);
        h_nvnCommandBufferSetGeometryProcessingMode(&cb,2);
        CHECK(CB(&cb)->geometry_mode==2,"NVN2 geometry mode is retained for mesh-task recording");
        h_nvnCommandBufferSetGeometryProcessingMode(&cb,0);
        P(nvnCommandBufferCopyBufferToBuffer)(&cb,(uint64_t)src,(uint64_t)dst,1024,0);
        P(nvnCommandBufferFenceSync)(&cb,&fence,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
        NVNcommandHandle handle=P(nvnCommandBufferEndRecording)(&cb);
        CHECK(dst[0]==0 && dst[1023]==0,"recording has no copy side effect");
        P(nvnQueueSubmitCommands)(&queues[mode],1,&handle);
        int wait=P(nvnSyncWait)(&fence,5000000000ull);
        CHECK(wait==NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED || wait==NVN_SYNC_WAIT_RESULT_CONDITION_SATISFIED,
              "recorded fence completes");
        CHECK(!memcmp(src,dst,1024),"recorded copy is visible after its fence");
        P(nvnSyncFinalize)(&fence); P(nvnCommandBufferFinalize)(&cb);
    }
    uint64_t first_serial = ((queue_t *)&queues[0])->serial;
    mtl_queue_activate(first_serial); S.tex_base = 123; R.has_sc = 1; R.sc.x = 77;
    mtl_queue_activate(((queue_t *)&queues[1])->serial);
    CHECK(S.tex_base == 0 && !R.has_sc && !S.bst[0],"a new queue starts with independent default state");
    S.tex_base = 456;
    mtl_queue_activate(first_serial);
    CHECK(S.tex_base == 123 && R.has_sc && R.sc.x == 77,"switching back restores the first queue state");
    mtl_queue_activate(((queue_t *)&queues[1])->serial);
    CHECK(S.tex_base == 456 && !R.has_sc,"the second queue keeps its own bindings");
    mtl_queue_activate(first_serial); S.bst[0] = S.prog = (const prog_t *)(uintptr_t)0xdead0000;
    P(nvnQueueFinalize)(&queues[0]);
    P(nvnDeviceSetWindowOriginMode)(&device,(NVNwindowOriginMode)0);
    NVNqueueBuilder fresh = {0}; P(nvnQueueBuilderSetDefaults)(&fresh); P(nvnQueueBuilderSetDevice)(&fresh,&device);
    CHECK(P(nvnQueueInitialize)(&queues[0],&fresh),"queue storage can be initialized again");
    mtl_queue_activate(((queue_t *)&queues[0])->serial);
    CHECK(((queue_t *)&queues[0])->serial != first_serial && !S.bst[0] && !S.prog && !R.has_sc,"reinitializing a queue never inherits finalized program pointers");
    // Native GPU state: matching queue/device origins keep NVN's NDC facing;
    // differing origins reverse it. CW and CCW expectations are explicit here.
    const int front_in_clip[2][2][2] = {{{0,1},{1,0}},{{1,0},{0,1}}};
    for (int current=0;current<2;current++) for (int winding=0;winding<2;winding++)
    for (int cull=0;cull<4;cull++) for (int ccw=0;ccw<2;ccw++) for (int flip=0;flip<2;flip++) for (int queue=0;queue<2;queue++) {
        P(nvnDeviceSetWindowOriginMode)(&device,(NVNwindowOriginMode)current);
        float positions[3][4] = {{-1,-1,.5,1},{3,-1,.5,1},{-1,3,.5,1}};
        if (!ccw) { float tmp[4]; memcpy(tmp,positions[1],16); memcpy(positions[1],positions[2],16); memcpy(positions[2],tmp,16); }
        memcpy(vertices,positions,sizeof positions);
        state_reset(); memset(&R,0,sizeof R); used=0;
        p_set_rt rt = {.n=1}; rt.color[0]=&target; emit(OP_SET_RT,&rt,sizeof rt);
        p_clear_color clear = {.rgba={0,0,1,1},.mask=15}; emit(OP_CLEAR_COLOR,&clear,sizeof clear);
        p_bind_program bp = {.prog=&pg,.stages=3}; emit(OP_BIND_PROGRAM,&bp,sizeof bp);
        ds_st ds = {.df=NVN_DEPTH_FUNC_ALWAYS}; p_bind_state bs = {.kind=5}; memcpy(bs.bytes,&ds,sizeof ds); emit(OP_BIND_STATE,&bs,sizeof bs);
        poly_st poly = {.cull=cull,.front=winding,.mode=NVN_POLYGON_MODE_FILL}; bs.kind=4; memcpy(bs.bytes,&poly,sizeof poly); emit(OP_BIND_STATE,&bs,sizeof bs);
        struct { int32_t first,n; va_st attr; } attr = {0,1,{.fmt=NVN_FORMAT_RGBA32F}}; emit(OP_BIND_VATTR,&attr,sizeof attr);
        struct { int32_t first,n; vs_st stream; } stream = {0,1,{.stride=16}}; emit(OP_BIND_VSTREAM,&stream,sizeof stream);
        p_bind_vbuf1 vb = {.index=0,.size=sizeof positions,.addr=(uint64_t)vertices}; emit(OP_BIND_VBUF1,&vb,sizeof vb);
        p_vp_swizzle sw = {.n=1}; sw.sw[0][1]=flip; emit(OP_VP_SWIZZLE,&sw,sizeof sw);
        p_draw draw = {.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1}; emit(OP_DRAW,&draw,sizeof draw); emit(OP_END,NULL,0);
        NVNcommandHandle handle = (NVNcommandHandle)commands;
        P(nvnQueueSubmitCommands)(&queues[queue],1,&handle); P(nvnQueueFinish)(&queues[queue]);
        int front = ccw == (front_in_clip[queue][current][winding] ^ flip);
        int visible = cull == NVN_FACE_NONE || (cull == NVN_FACE_FRONT && !front) || (cull == NVN_FACE_BACK && front);
        g_fd_dw=&draw;
        CHECK(first_draw_covers(0,tex_mtl(&target),0)==visible,"full-coverage proof agrees with native culling");
        g_fd_dw=NULL;
        uint8_t expected[4] = {visible && !front ? 255:0,visible && front ? 255:0,visible ? 0:255,255};
        id<MTLBuffer> pixels = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
        mtl_sub_begin(); res_add(pixels);
        enc_b_copy_texture_buffer(blit(),tex_mtl(&target),0,0,MTLOriginMake(0,0,0),MTLSizeMake(8,8,1),pixels,0,32,256);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull),"pixel readback completes");
        int good=1; for (int i=0;i<64;i++) good &= !memcmp((uint8_t *)pixels.contents+4*i,expected,4);
        if (!good) fprintf(stderr,"queue origin=%d device origin=%d front=%d cull=%d triangle CCW=%d\n",queue,current,winding,cull,ccw);
        CHECK(good,"queue-latched culling and front_facing match native GPU state");
    }
    mtl_pool_del(vertices); free(vertices);
    printf("queue origin: %d checks, %d failed\n",checks,fails); return fails != 0;
} }
