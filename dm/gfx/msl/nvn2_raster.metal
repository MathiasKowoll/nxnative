// Raster adapter for the first confirmed NVN2 task/mesh ABI. The translated
// task and mesh programs run as compute kernels and write the private ISBE
// scratch layout; this native Metal mesh stage presents those outputs to the
// original translated fragment function.
#include <metal_stdlib>
using namespace metal;

constant uint dm_space_words = 0x10000u;
constant uint dm_mesh_output_word = 0x20000u;
constant uint dm_mesh_group_words = 0x30000u;
constant uint dm_dispatch_word = 0x10004u;

struct dm_vertex_l1 {
    float4 position [[position]];
    float4 locn0 [[user(locn0)]];
};

struct dm_vertex_l2 {
    float4 position [[position]];
    float4 locn0 [[user(locn0), flat]];
    float4 locn1 [[user(locn1)]];
};

struct dm_vertex_l6 {
    float4 position [[position]];
    float4 locn0 [[user(locn0), flat]];
    float4 locn1 [[user(locn1), flat]];
    float4 locn2 [[user(locn2), flat]];
    float4 locn3 [[user(locn3), flat]];
    float4 locn4 [[user(locn4)]];
    float4 locn5 [[user(locn5)]];
};

struct dm_primitive {
    bool culled [[primitive_culled]];
};

static float4 dm_attribute(device const uint *scratch, uint group, uint vertex_index, uint attribute) {
    uint base = dm_mesh_output_word + group * dm_mesh_group_words + dm_space_words;
    uint lane = (vertex_index & 31u) * 4u + (vertex_index >> 5u) * 1024u;
    return float4(as_type<float>(scratch[base + lane + attribute * 512u + 0u * 128u]),
                  as_type<float>(scratch[base + lane + attribute * 512u + 1u * 128u]),
                  as_type<float>(scratch[base + lane + attribute * 512u + 2u * 128u]),
                  as_type<float>(scratch[base + lane + attribute * 512u + 3u * 128u]));
}

[[mesh, max_total_threads_per_threadgroup(64)]]
void nvn2_raster_l1(mesh<dm_vertex_l1, dm_primitive, 32, 64, topology::triangle> out,
                    device const uint *scratch [[buffer(0)]],
                    uint group [[threadgroup_position_in_grid]],
                    uint lane [[thread_index_in_threadgroup]]) {
    uint groups = min(scratch[dm_dispatch_word], 32u);
    if (group >= groups) {
        if (lane == 0u) out.set_primitive_count(0u);
        return;
    }

    uint group_base = dm_mesh_output_word + group * dm_mesh_group_words;
    uint primitive_count = min(scratch[group_base + 3u], 64u);
    if (lane < 32u) {
        out.set_vertex(lane, dm_vertex_l1{dm_attribute(scratch, group, lane, 0u),
                                         dm_attribute(scratch, group, lane, 1u)});
    }
    if (lane < primitive_count) {
        uint index_base = group_base + 2u * dm_space_words + 4u + lane * 3u;
        out.set_index(lane * 3u + 0u, scratch[index_base + 0u] & 0xffu);
        out.set_index(lane * 3u + 1u, scratch[index_base + 1u] & 0xffu);
        out.set_index(lane * 3u + 2u, scratch[index_base + 2u] & 0xffu);
        out.set_primitive(lane, dm_primitive{false});
    }
    if (lane == 0u) out.set_primitive_count(primitive_count);
}

// Mario Kart World's compact culling pass emits clip position plus two
// fragment attributes. Location zero is flat; location one interpolates.
[[mesh, max_total_threads_per_threadgroup(64)]]
void nvn2_raster_l2(mesh<dm_vertex_l2, dm_primitive, 32, 64, topology::triangle> out,
                    device const uint *scratch [[buffer(0)]],
                    uint group [[threadgroup_position_in_grid]],
                    uint lane [[thread_index_in_threadgroup]]) {
    uint groups = min(scratch[dm_dispatch_word], 32u);
    if (group >= groups) {
        if (lane == 0u) out.set_primitive_count(0u);
        return;
    }

    uint group_base = dm_mesh_output_word + group * dm_mesh_group_words;
    uint primitive_count = min(scratch[group_base + 3u], 64u);
    if (lane < 32u) {
        out.set_vertex(lane, dm_vertex_l2{dm_attribute(scratch, group, lane, 0u),
                                         dm_attribute(scratch, group, lane, 1u),
                                         dm_attribute(scratch, group, lane, 2u)});
    }
    if (lane < primitive_count) {
        uint index_base = group_base + 2u * dm_space_words + 4u + lane * 3u;
        out.set_index(lane * 3u + 0u, scratch[index_base + 0u] & 0xffu);
        out.set_index(lane * 3u + 1u, scratch[index_base + 1u] & 0xffu);
        out.set_index(lane * 3u + 2u, scratch[index_base + 2u] & 0xffu);
        out.set_primitive(lane, dm_primitive{false});
    }
    if (lane == 0u) out.set_primitive_count(primitive_count);
}

// Second confirmed Mario Kart World mesh ABI. Attribute zero is the clip-space
// position; the following six attributes match fragment locations 0...5. The
// first four fragment inputs are flat, while locations 4 and 5 interpolate.
[[mesh, max_total_threads_per_threadgroup(64)]]
void nvn2_raster_l6(mesh<dm_vertex_l6, dm_primitive, 32, 64, topology::triangle> out,
                    device const uint *scratch [[buffer(0)]],
                    uint group [[threadgroup_position_in_grid]],
                    uint lane [[thread_index_in_threadgroup]]) {
    uint groups = min(scratch[dm_dispatch_word], 32u);
    if (group >= groups) {
        if (lane == 0u) out.set_primitive_count(0u);
        return;
    }

    uint group_base = dm_mesh_output_word + group * dm_mesh_group_words;
    uint primitive_count = min(scratch[group_base + 3u], 64u);
    if (lane < 32u) {
        out.set_vertex(lane, dm_vertex_l6{dm_attribute(scratch, group, lane, 0u),
                                         dm_attribute(scratch, group, lane, 1u),
                                         dm_attribute(scratch, group, lane, 2u),
                                         dm_attribute(scratch, group, lane, 3u),
                                         dm_attribute(scratch, group, lane, 4u),
                                         dm_attribute(scratch, group, lane, 5u),
                                         dm_attribute(scratch, group, lane, 6u)});
    }
    if (lane < primitive_count) {
        uint index_base = group_base + 2u * dm_space_words + 4u + lane * 3u;
        out.set_index(lane * 3u + 0u, scratch[index_base + 0u] & 0xffu);
        out.set_index(lane * 3u + 1u, scratch[index_base + 1u] & 0xffu);
        out.set_index(lane * 3u + 2u, scratch[index_base + 2u] & 0xffu);
        out.set_primitive(lane, dm_primitive{false});
    }
    if (lane == 0u) out.set_primitive_count(primitive_count);
}
