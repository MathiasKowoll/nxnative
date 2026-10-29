// Absolute c2 handle indices must reach the separate texture table (45..172).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static id<MTLTexture> texture(tex_t *t, uint64_t serial) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=serial};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8,
        .width=4, .height=4, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> r = [g_dev newTextureWithDescriptor:d];
    CHECK(r != nil, "texture created"); res_add(r); mtl_tex_init(t); serial_put(serial, r); return r;
}
int main(void) { @autoreleasepool {
    mtl_init(); NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) {return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1); }\n"
        "struct A {array<texture2d<float>,173> tex[[id(0)]];array<sampler,173> samp[[id(173)]];constant uint *c2[[id(346)]];};\n"
        "float4 read(float4 p,constant A&a,uint cap) {uint x=uint(p.x);uint idx=x==0?4:x==1?45:x==2?46:172;"
        "if(a.c2[idx*2] != 600+x)return float4(1,0,1,1);uint at=min(idx,cap);return a.tex[at].sample(a.samp[at],float2(.5));}\n"
        "fragment float4 f(float4 p[[position]],constant A&a[[buffer(0)]]) {return read(p,a,172); }\n"
        "fragment float4 old(float4 p[[position]],constant A&a[[buffer(0)]]) {return read(p,a,31); }\n";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error];
    CHECK(lib != nil, "synthetic driver-array shader compiles");
    if (!lib) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1; }
    const uint8_t colors[4][4] = {{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}};
    const int slots[4] = {0,128,129,255}; tex_t input[4], output;
    for (int i=0;i<4;i++) {
        id<MTLTexture> t=texture(&input[i],99000+i); uint8_t pixels[64];
        for(int k=0;k<16;k++)memcpy(pixels+4*k,colors[i],4);
        [t replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:pixels bytesPerRow:16];
        mtl_reg_tex(600+i,&input[i],NULL);
    }
    samp_par sampler={.lod_max=16,.aniso=1}; mtl_reg_samp(900,&sampler);
    id<MTLTexture> dst=texture(&output,99010);
    for (int control=0;control<2;control++) {
        NvShader *fs=[NvShader new]; fs->stage=1; strcpy(fs->key,"driver-array-test");
        fs->fn=[lib newFunctionWithName:control?@"old":@"f"];
        fs->ae=[fs->fn newArgumentEncoderWithBufferIndex:0]; fs->arg_len=fs->ae.encodedLength;
        CHECK(fs->arg_len==347*8,"full table argument buffer layout");
        fs->rf.nb=3; fs->rf.drv_read[2]=1;
        fs->rf.b[0]=(nvn_rbind){.kind=NVN_RB_TEXA,.aid=0,.n=173,.dtt=MTLTextureType2D};
        fs->rf.b[1]=(nvn_rbind){.kind=NVN_RB_SAMP,.aid=173,.reg=1,.n=173};
        fs->rf.b[2]=(nvn_rbind){.kind=NVN_RB_DRV2,.aid=346};
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
        pd.vertexFunction=[lib newFunctionWithName:@"v"]; pd.fragmentFunction=fs->fn;
        pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> ps=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];
        CHECK(ps!=nil,"driver-array pipeline compiles");if(!ps)return 1;
        state_reset();memset(&R,0,sizeof R);mtl_sub_begin();
        for(int i=0;i<4;i++)S.tex[1][slots[i]]=600+i;
        S.samp[1][1]=(uint64_t)900<<20;
        R.has_rt=1;R.rt.n=1;R.rt.color[0]=&output;R.clear_c[0]=1;
        CHECK(rp_begin()!=nil,"production render pass opens");
        enc_r_pso(g_enc,ps);enc_r_viewport(g_enc,(MTLViewport){0,0,4,4,0,1});
        CHECK(encode_args((id<MTLCommandEncoder>)g_enc,fs,1,0),"production full-table arguments encoded");
        enc_r_draw(g_enc,MTLPrimitiveTypeTriangle,0,3);rp_end();
        id<MTLBuffer> result=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];res_add(result);
        enc_b_copy_texture_buffer(blit(),dst,0,0,MTLOriginMake(0,0,0),MTLSizeMake(4,4,1),result,0,256,1024);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull),"GPU submission completes");
        CHECK(!mtl_last_commit_error(),"GPU submission has no error");
        const uint8_t *pixels=result.contents;
        for(int x=0;x<4;x++) {
            int equal=!memcmp(pixels+x*4,colors[x],4);
            CHECK(control&&x>0?!equal:equal, control?"old 32-entry cap fails separate textures":"combined and separate texture pixels match");
        }
    }
    printf("driver arrays: %d checks, %d failed\n",checks,failed);return failed!=0;
} }
