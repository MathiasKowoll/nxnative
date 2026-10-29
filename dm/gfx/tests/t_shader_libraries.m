// Load an external game's compiled libraries through the production loader.
// Usage: t_shader_libraries <cache/b-chain>; no game assets are stored here.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2)return 2;
    mtl_init(); g_msl_dir=@(argv[1]); unsigned loaded=0,folded=0,failed=0;
    NSError *error=nil; NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:g_msl_dir error:&error];
    if(!files){fprintf(stderr,"%s\n",error.description.UTF8String);return 2;}
    NSDictionary *stages=@{@"vs":@0,@"ps":@1,@"gs":@2,@"hs":@3,@"ds":@4,@"cs":@5};
    for(NSString *name in [files sortedArrayUsingSelector:@selector(compare:)]) { @autoreleasepool {
        if(![name hasSuffix:@"_b.json"])continue;
        NSDictionary *j=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[g_msl_dir stringByAppendingPathComponent:name]] options:0 error:&error];
        if(j[@"gs_slice"]){folded++;continue;}
        NSNumber *stage=stages[j[@"stage"]];
        if(!stage){fprintf(stderr,"unknown stage %s\n",name.UTF8String);failed++;continue;}
        NvShader *sh=shader_load([name stringByDeletingPathExtension],stage.intValue,0);
        if(!sh){fprintf(stderr,"failed to load %s\n",name.UTF8String);failed++;continue;}
        if(j[@"entry_dual"]&&!sh->fn_dual)failed++;
        if(j[@"entry_u"]&&!sh->fn_u)failed++;
        if(j[@"entry_u_or"]&&!sh->fn_u_or)failed++;
        if(j[@"entry_m"]&&!sh->fn_m)failed++;
        loaded++;
    } }
    printf("%u libraries loaded, %u geometry folds, %u failures\n",loaded,folded,failed);
    return failed||!loaded?1:0;
} }
