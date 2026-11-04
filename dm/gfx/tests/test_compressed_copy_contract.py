"""Source-level invariants for block-compressed texture copies."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class CompressedCopyContractTests(unittest.TestCase):
    def test_t2t_copy_expands_partial_texel_sizes_to_complete_blocks(self):
        source = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        self.assertIn("static int copy_t2t_block_size", source)
        self.assertIn(
            "NSUInteger aw = (sz->width + (NSUInteger)bw - 1) / "
            "(NSUInteger)bw * (NSUInteger)bw;",
            source,
        )
        self.assertIn(
            "NSUInteger ah = (sz->height + (NSUInteger)bh - 1) / "
            "(NSUInteger)bh * (NSUInteger)bh;",
            source,
        )
        self.assertIn("sz->width = so.x + aw <= sw ? aw : se_w ? sz->width : 0;", source)
        self.assertIn("dz->height = do_.y + ah <= dh ? ah : de_h ? dz->height : 0;", source)
        self.assertIn("int staged = sz->width != dz->width || sz->height != dz->height;", source)
        self.assertIn("if (block_copy == 2)", source)
        self.assertIn('getenv("DM_NVN_T2T_STAGE")', source)
        self.assertIn("enc_b_copy_texture_buffer", source)
        self.assertIn("enc_b_copy_buffer_texture", source)

    def test_t2t_copy_does_not_resample_or_change_format(self):
        source = (ROOT / "gfx/nvn/nvn_mtl.m").read_text()
        helper = source[source.index("static int copy_t2t_block_size") :]
        helper = helper[: helper.index("static void copy_t2t(")]
        self.assertIn("s.pixelFormat != d.pixelFormat", helper)
        self.assertNotIn("copy_t2t_draw", helper)
        self.assertNotIn("tex_upgrade", helper)


if __name__ == "__main__":
    unittest.main()
