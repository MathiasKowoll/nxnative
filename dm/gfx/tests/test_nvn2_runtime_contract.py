"""Source-level invariants for the NVN2 task/mesh replay boundary."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class Nvn2RuntimeContractTests(unittest.TestCase):
    def test_compact_runtime_key_includes_the_c1_segment(self):
        source = (ROOT / "gfx/nvn/nvn_shader_control.h").read_text()
        self.assertIn("memcpy(ncode, p + 0x44, 4);", source)
        self.assertNotIn("memcpy(ncode, p + 0x40, 4);", source)

    def test_native_raster_does_not_encode_task_as_vertex_stage(self):
        source = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        self.assertIn(
            "if (pr->sh[0] && g_geo_mesh.on != 2) "
            "encode_args(en, pr->sh[0], 0, 1);",
            source,
        )

    def test_scratch_binding_remains_limited_to_task_and_mesh_stages(self):
        source = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        self.assertIn(
            "if ((nvn_stage != 6 && nvn_stage != 7) || "
            "!g_nvn2_scratch_buf || !g_nvn2_scratch_gpu)",
            source,
        )

    def test_scratch_is_reused_once_per_mode_and_submission_and_gpu_initialized(self):
        source = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        metal = (ROOT / "gfx/msl/nvn2_raster.metal").read_text()
        self.assertIn("g_nvn2_scratch_sub[slot] != g_sub_serial", source)
        self.assertIn("g_nvn2_scratch_mode_buf[2]", source)
        self.assertEqual(source.count("arena_alloc(DMSH_NVN2_SCRATCH_BYTES"), 1)
        self.assertIn("kernel void nvn2_scratch_init", metal)
        self.assertIn("scratch[dm_mesh_output_word + lane * dm_mesh_group_words + 3u] = 0u;", metal)
        self.assertIn("MTLSizeMake(DMSH_NVN2_MAX_MESH_GROUPS, 1, 1)", source)
        self.assertIn("nvn2_scratch_prepare(ce, d->mode, (uint32_t)(d->first + object), 0)", source)

    def test_native_raster_culls_indices_outside_its_declared_vertex_bound(self):
        metal = (ROOT / "gfx/msl/nvn2_raster.metal").read_text()
        self.assertIn("constant uint dm_max_mesh_vertices = 32u;", metal)
        self.assertEqual(
            metal.count("bool valid = all(indices < dm_max_mesh_vertices);"),
            4,
        )
        self.assertEqual(
            metal.count("out.set_primitive(lane, dm_primitive{!valid});"),
            4,
        )
        self.assertNotIn("scratch[index_base + 0u] & 0xffu);", metal)

    def test_native_raster_modes_can_be_isolated_without_disabling_compute(self):
        source = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        probe = (ROOT.parent / "scripts/probe_extracted_game.py").read_text()
        self.assertIn('getenv("DM_NVN2_RASTER_MODE")', source)
        self.assertIn("nvn2_mesh_raster_on(d->mode)", source)
        self.assertIn("--mesh-raster-mode", probe)
        self.assertIn('"DM_NVN2_DIRECT_RASTER_KEYS"', source)
        self.assertIn("--direct-raster-keys", probe)
        self.assertIn('"DM_NVN2_TASK_RASTER_KEYS"', source)
        self.assertIn("--task-raster-keys", probe)
        self.assertIn("gpu-page-fault", probe)

    def test_sparse_runtime_can_measure_physical_guest_backing(self):
        hle = (ROOT / "gfx/nvn/hle_nvn.c").read_text()
        mtl = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        self.assertIn("uint64_t nvn_sparse_mapped_bytes", hle)
        self.assertIn("uint64_t nvn_sparse_tilemap", hle)
        self.assertIn("nvn_sparse_mapped_bytes(t->pool", mtl)

    def test_nvn2_first_mesh_raster_draw_is_not_dropped_for_background_compile(self):
        geometry = (ROOT / "gfx/nvn/nvn_geometry.inc").read_text()
        self.assertIn("if (g_geo_mesh.on == 2) {", geometry)
        self.assertIn("NVN2 mesh raster pipeline:", geometry)
        foreground, background = geometry.split("if (g_geo_mesh.on == 2) {", 1)[1].split("} else {", 1)
        self.assertIn("newRenderPipelineStateWithMeshDescriptor", foreground)
        self.assertNotIn("dispatch_async", foreground)
        self.assertIn("dispatch_async", background)

    def test_native_sparse_can_be_selected_by_the_game_profile(self):
        mtl = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        game = (ROOT / "games/game.py").read_text()
        self.assertIn("DM_GAME_NATIVE_SPARSE", mtl)
        self.assertIn("g.get('native_sparse', 'off')", game)
        self.assertIn("#define DM_GAME_NATIVE_SPARSE", game)

    def test_drive_fragment_interface_uses_the_two_attribute_raster_adapter(self):
        source = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        layout_two = source.split('!strncmp(fragment->key, "7104fedf8c9d9d96", 16)', 1)[1]
        layout_two = layout_two.split('? 2 :', 1)[0]
        self.assertIn('!strncmp(fragment->key, "ae62ba75b82badc8", 16)', layout_two)
        self.assertIn('!strncmp(fragment->key, "fec8ca2d85686848", 16)', layout_two)

    def test_flat_single_attribute_fragment_has_a_matching_raster_adapter(self):
        source = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        metal = (ROOT / "gfx/msl/nvn2_raster.metal").read_text()
        self.assertIn('!strncmp(fragment->key, "286d21df3059403a", 16) ? 3', source)
        self.assertIn("struct dm_vertex_l1_flat", metal)
        self.assertIn("float4 locn0 [[user(locn0), flat]];", metal)
        self.assertIn("void nvn2_raster_l1_flat", metal)

    def test_compute_pipeline_failures_name_the_guest_shader_and_grid(self):
        source = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        self.assertIn("background compute pipeline %s creation failed", source)
        self.assertIn("failed to create compute pipeline %s for grid %ux%ux%u", source)


if __name__ == "__main__":
    unittest.main()
