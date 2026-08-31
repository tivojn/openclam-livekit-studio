"""Authored-shape gaze invariants; no model downloads or private test assets."""
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import authored_gaze
from studio.blink import UPPER, LOWER


def fixture(scale=1):
    size = 1024
    image = np.full((size, size, 3), (95, 157, 216), np.uint8)
    lm = np.full((478, 2), (512, 512), np.float32)
    masks = {}
    for side, cx in (("r", 400), ("l", 625)):
        cy = 420
        eye = np.zeros((size, size), np.uint8)
        cv2.ellipse(eye, (cx, cy), (64, 55), -8, 0, 360, 255, -1)
        yy, xx = np.mgrid[:size, :size]
        sclera = np.clip(242+(xx-cx)/18+(yy-cy)/40, 230, 250).astype(np.uint8)
        image[eye > 0] = np.repeat(sclera[..., None], 3, axis=2)[eye > 0]
        cv2.ellipse(image, (cx, cy), (65, 56), -8, 0, 360, (8, 11, 13), 3)
        # Deliberately non-round/asymmetric authored silhouette. Its notch and
        # all paint must translate unchanged, not become a fitted circle.
        polygon = np.array([[-20,-34],[5,-38],[24,-23],[27,-2],[17,5],
                            [24,16],[9,35],[-9,39],[-26,20],[-29,-9]], np.int32)
        polygon += [cx, cy]
        fg = np.zeros_like(eye)
        cv2.fillPoly(fg, [polygon], 255)
        image[fg > 0] = (35, 65, 117)
        cv2.rectangle(image, (cx-12, cy-13), (cx+5, cy+21), (3, 5, 8), -1)
        cv2.line(image, (cx-20, cy+12), (cx-14,cy+25), (51,94,151), 2)
        cv2.circle(image, (cx-4,cy-19), 7, (253,253,253), -1)
        cv2.circle(image, (cx+12,cy+19), 3, (245,249,250), -1)
        masks[side] = fg > 0
        # These human lids intentionally bisect the art, like actual Celine.
        xs = np.linspace(cx-48, cx+48, 9)
        curvature = np.sqrt(np.maximum(0, 1-((xs-cx)/48)**2))
        lm[UPPER[side]] = np.column_stack([xs, cy-12-27*curvature])
        lm[LOWER[side]] = np.column_stack([xs, cy-12+8*curvature])
        lm[authored_gaze.IRIS[side]] = [cx+5,cy-18]
        cv2.line(image, (cx-55,cy-68), (cx+52,cy-68), (4,5,6), 4)
    box = (345,374,110,58)
    if scale != 1:
        image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_NEAREST)
        lm *= scale
        box = tuple(int(v*scale) for v in box)
    return image, lm, box, masks


def over(base, patch):
    a = patch[...,3:4].astype(np.float32)/255
    return np.rint(base*(1-a)+patch[...,:3]*a).astype(np.uint8)


class AuthoredGazeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image, cls.lm, cls.box, cls.masks = fixture()
        cls.p = authored_gaze.prepare(cls.image, cls.lm, "r", cls.box)

    def test_measured_artwork_can_expand_beyond_wrong_human_lid_box(self):
        p = self.p
        self.assertGreater(p.box[1]+p.box[3], self.box[1]+self.box[3]+25)
        self.assertEqual(p.metadata()["shape_fit"], "none")
        self.assertEqual(p.metadata()["mode"], "authored-2d-rigid-iris-v1")
        x,y,w,h = p.box
        # The exact non-convex source foreground survives measurement.
        np.testing.assert_array_equal(p.observed_foreground, self.masks["r"][y:y+h,x:x+w])

    def test_neutral_is_pixel_exact_and_prepare_does_not_change_inputs(self):
        image,lm,box,_ = fixture()
        before, points = image.copy(),lm.copy()
        p = authored_gaze.prepare(image,lm,"r",box)
        patch = authored_gaze.state(p,0,0)
        np.testing.assert_array_equal(patch[...,:3],p.base)
        self.assertFalse(patch[...,3].any())
        np.testing.assert_array_equal(over(p.base,patch),p.base)
        np.testing.assert_array_equal(image,before)
        np.testing.assert_array_equal(lm,points)

    def test_full_authored_foreground_and_catchlights_translate_exactly(self):
        p = self.p
        yy,xx = np.where(p.observed_foreground)
        self.assertGreater(int((p.base[yy,xx].min(axis=1)>240).sum()),100)
        for dx,dy in ((-9,0),(9,0),(0,-3),(0,3),(-9,3),(9,-3)):
            with self.subTest(dx=dx,dy=dy):
                patch=authored_gaze.state(p,dx,dy)
                tx,ty=xx+dx,yy+dy
                valid=(tx>=0)&(tx<p.box[2])&(ty>=0)&(ty<p.box[3])
                sx,sy,tx,ty=xx[valid],yy[valid],tx[valid],ty[valid]
                valid=p.aperture[ty,tx]
                np.testing.assert_array_equal(patch[ty[valid],tx[valid],:3],p.base[sy[valid],sx[valid]])

    def test_pupil_and_catchlight_keep_shape_not_only_centroid(self):
        p=self.p
        black=(p.base.max(axis=2)<15)&p.observed_foreground
        glint=(p.base.min(axis=2)>240)&p.observed_foreground
        for source in (black,glint):
            for dx,dy in ((-9,0),(9,0),(0,-3),(0,3)):
                translated=cv2.warpAffine(source.astype(np.uint8),np.float32([[1,0,dx],[0,1,dy]]),
                                           (p.box[2],p.box[3]),flags=cv2.INTER_NEAREST)>0
                rgb=over(p.base,authored_gaze.state(p,dx,dy))
                moved_core=cv2.warpAffine(p.observed_foreground.astype(np.uint8),
                                          np.float32([[1,0,dx],[0,1,dy]]),(p.box[2],p.box[3]),
                                          flags=cv2.INTER_NEAREST)>0
                actual=((rgb.max(axis=2)<15) if source is black else (rgb.min(axis=2)>240))&moved_core&p.aperture
                np.testing.assert_array_equal(actual,translated&p.aperture)

    def test_old_iris_footprint_is_fully_erased_not_translucently_doubled(self):
        p=self.p
        for dx,dy in ((-9,0),(9,0),(0,-3),(0,3)):
            patch=authored_gaze.state(p,dx,dy)
            moved=cv2.remap(p.iris_alpha,p.grid_x-dx,p.grid_y-dy,cv2.INTER_LINEAR)
            vacated=(p.iris_alpha>0)&(moved==0)&p.aperture
            self.assertGreater(int(vacated.sum()),70)
            self.assertTrue((patch[...,3][vacated]==255).all())
            np.testing.assert_array_equal(patch[...,:3][vacated],np.rint(p.sclera[vacated]).astype(np.uint8))
            self.assertGreater(float(p.sclera[vacated].min()),225)

    def test_all_275_states_preserve_fixed_lashes_sclera_and_skin(self):
        p=self.p
        dxs=np.linspace(-9,9,25)
        dys=np.linspace(-3.5,3.5,11)
        for dy in dys:
            for dx in dxs:
                patch=authored_gaze.state(p,dx,dy)
                self.assertFalse(patch[...,3][~p.aperture].any())
                rgb=over(p.base,patch)
                np.testing.assert_array_equal(rgb[~p.aperture],p.base[~p.aperture])
                unchanged=patch[...,3]==0
                np.testing.assert_array_equal(rgb[unchanged],p.base[unchanged])
        x,y,w,h=p.box
        result=self.image.copy()
        result[y:y+h,x:x+w]=over(p.base,authored_gaze.state(p,-9,-3.5))
        protected=np.ones(result.shape[:2],bool)
        protected[y:y+h,x:x+w]=~p.aperture
        np.testing.assert_array_equal(result[protected],self.image[protected])

    def test_fractional_motion_is_one_premultiplied_translation(self):
        p=self.p
        for dx,dy in ((.25,-.375),(-1.5,2.5),(7.5,-3.5)):
            patch=authored_gaze.state(p,dx,dy)
            a=cv2.remap(p.iris_alpha,p.grid_x-dx,p.grid_y-dy,cv2.INTER_LINEAR)
            texture=cv2.remap(p.texture_premultiplied,p.grid_x-dx,p.grid_y-dy,cv2.INTER_LINEAR)
            core=(a==1)&p.aperture
            self.assertGreater(int(core.sum()),1000)
            np.testing.assert_array_equal(patch[...,:3][core],np.rint(texture[core]).astype(np.uint8))

    def test_sclera_fill_uses_no_iris_paint_and_keeps_known_pixels_exact(self):
        p=self.p
        known=p.iris_alpha==0
        np.testing.assert_array_equal(p.sclera[known],p.base[known])
        self.assertGreater(float(p.sclera[p.observed_foreground].min()),225)
        self.assertTrue(np.isfinite(p.sclera).all())

    def test_unsupported_iris_that_merges_with_lash_fails_closed(self):
        self.assertEqual(authored_gaze.NEUTRAL_MODE, "authored-2d-neutral-gaze-v1")
        self.assertNotEqual(authored_gaze.NEUTRAL_MODE, authored_gaze.MODE)
        image,lm,box,_=fixture()
        cv2.line(image,(400,383),(400,360),(5,5,5),5)
        with self.assertRaises(authored_gaze.UnsupportedAuthoredIris):
            authored_gaze.prepare(image,lm,"r",box)
        fallback=authored_gaze.neutral(image,box)
        self.assertFalse(fallback[...,3].any())
        np.testing.assert_array_equal(fallback[...,:3],image[box[1]:box[1]+box[3],box[0]:box[0]+box[2]])

    def test_coloured_or_absent_sclera_is_not_normalized_to_white(self):
        image,lm,box,_=fixture()
        white=(image.min(axis=2)>220)
        image[white]=(55,220,60)
        with self.assertRaises(authored_gaze.UnsupportedAuthoredIris):
            authored_gaze.prepare(image,lm,"r",box)
        with self.assertRaises(authored_gaze.UnsupportedAuthoredIris):
            authored_gaze.prepare(np.full_like(image,220),lm,"r",box)

    def test_scaled_artwork_does_not_depend_on_roundness(self):
        image,lm,box,_=fixture(.5)
        p=authored_gaze.prepare(image,lm,"r",box)
        self.assertEqual(p.metadata()["shape_fit"],"none")
        self.assertEqual(p.limits,(4.5,1.75))
        self.assertTrue(np.isfinite(authored_gaze.state(p,4.5,1.75)).all())

    def test_no_per_tile_segmentation_or_background_reconstruction(self):
        with mock.patch.object(authored_gaze,"_observe",side_effect=AssertionError("reobserve")), \
             mock.patch.object(authored_gaze,"_clean_sclera",side_effect=AssertionError("refill")):
            for dy in np.linspace(-3.5,3.5,11):
                for dx in np.linspace(-9,9,25):
                    authored_gaze.state(self.p,dx,dy)

    def test_invalid_requests_rejected_and_excessive_travel_bounded(self):
        for values in ((np.nan,0),(0,np.inf)):
            with self.assertRaises(ValueError):
                authored_gaze.state(self.p,*values)
        np.testing.assert_array_equal(authored_gaze.state(self.p,1e5,-1e5),
                                      authored_gaze.state(self.p,9,-3.5))
        lm=self.lm.copy();lm[468]=np.nan
        with self.assertRaises(ValueError):
            authored_gaze.prepare(self.image,lm,"r",self.box)
        with self.assertRaises(ValueError):
            authored_gaze.prepare(self.image,self.lm,"r",(-1,0,100,100))
        with self.assertRaises(ValueError):
            authored_gaze.prepare(self.image.astype(np.float32),self.lm,"r",self.box)


if __name__=="__main__":
    unittest.main()
