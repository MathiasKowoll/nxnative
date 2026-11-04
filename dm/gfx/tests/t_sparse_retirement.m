// A residency-set commit can release its last reference to a sparse texture.
// Its heap owner must retire the backing without re-entering the residency lock.
#include <signal.h>
#include <unistd.h>
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static void timeout_handler(int sig) { (void)sig; _exit(124); }
int main(void) { @autoreleasepool {
    signal(SIGALRM, timeout_handler); alarm(10);
    g_dev = MTLCreateSystemDefaultDevice();
    if (![g_dev supportsFamily:MTLGPUFamilyApple8]) { puts("SKIP: placement sparse requires Apple8"); return 0; }
    g_res = [g_dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.type = MTLHeapTypePlacement;
    hd.storageMode = MTLStorageModePrivate; hd.size = 65536; hd.maxCompatiblePlacementSparsePageSize = MTLSparsePageSize64;
    id<MTLHeap> heap = [g_dev newHeapWithDescriptor:hd];
    __weak NvSparseHeap *weakOwner;
    @autoreleasepool {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate; td.placementSparsePageSize = MTLSparsePageSize64;
        id<MTLTexture> texture = [g_dev newTextureWithDescriptor:td];
        NvSparseHeap *owner = [NvSparseHeap new]; owner->heap = heap; weakOwner = owner;
        objc_setAssociatedObject(texture, &g_sparse_heap_owner_key, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        res_add(heap); res_add(texture); res_commit();
        res_remove(texture);
        // Leaving this scope drops the host references. Metal can retain the
        // texture until the next commit applies its removal.
    }
    if (!weakOwner) { fputs("FAIL: fixture did not retain the texture until commit\n", stderr); return 1; }
    res_commit();
    int alive = weakOwner != nil;
    pthread_mutex_lock(&g_res_mu); int resident = [g_res_objects containsObject:heap]; pthread_mutex_unlock(&g_res_mu);
    if (alive || resident || [g_res containsAllocation:heap]) {
        fprintf(stderr, "FAIL: owner alive=%d heap resident=%d\n", alive, resident); return 1;
    }
    __weak id<MTLHeap> weakHeap = heap;
    heap = nil;
    defer_drain();
    @autoreleasepool {
        if (!weakHeap) { fputs("FAIL: retired heap released before submission completion\n", stderr); return 1; }
    }
    atomic_store(&g_done, g_fence + 1);
    defer_drain();
    if (weakHeap) { fputs("FAIL: retired heap retained after submission completion\n", stderr); return 1; }
    alarm(0); puts("PASS: sparse retirement is deadlock-free and retains its heap until submission completion"); return 0;
} }
