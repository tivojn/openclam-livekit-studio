"""Execute the actual soft-3D mouth-skin renderer helpers, without a browser."""
import json
from pathlib import Path
import re
import subprocess
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "web/index.html").read_text()


def run_js(body):
    names = (
        "stylizedMouthLipContour", "stylizedMouthContourDistance",
        "stylizedMouthBlurField", "stylizedMouthMaskAlpha",
        "correctStylizedMouthSkin",
    )
    helpers = []
    for name in names:
        match = re.search(rf"(const {name} = [\s\S]*?\n    (?:\}};|\);))", SOURCE)
        if match is None:
            raise AssertionError(f"Missing runtime helper: {name}")
        helpers.append(match[1])
    setup = """
      let manifest = {source_medium:'3d render',stylized_mouth:{skin_match:{
        v:1,space:'canonical-pixels',contours:{},emotion_contours:{}}}};
      const expressionSmoothStep = value => {
        const x = Math.max(0,Math.min(1,Number(value)||0));
        return x*x*(3-2*x);
      };
      const polygon = (cx=100,cy=50,rx=40,ry=15) =>
        Array.from({length:16},(_,i)=>[cx+rx*Math.cos(i*Math.PI/8),
          cy+ry*Math.sin(i*Math.PI/8)]);
      const fixture = (offset=x=>0) => {
        const width=200,height=100;
        const source=new Uint8ClampedArray(width*height*4);
        const neutral=new Uint8ClampedArray(source.length);
        for(let y=0;y<height;y++) for(let x=0;x<width;x++) {
          const i=(y*width+x)*4;
          const base=[160+.08*x,125+.05*y,105+.02*x];
          for(let c=0;c<3;c++) {
            neutral[i+c]=base[c];source[i+c]=base[c]+offset(x,y,c);
          }
          source[i+3]=neutral[i+3]=255;
        }
        return {width,height,source,neutral,contour:polygon()};
      };
    """
    result = subprocess.run(["node", "-e", setup+"\n"+"\n".join(helpers)+"\n"+body],
                            check=True, text=True, capture_output=True)
    return json.loads(result.stdout)


class MouthSkinRendererTests(unittest.TestCase):
    def test_explicit_soft_3d_only(self):
        result = run_js("""
          manifest.stylized_mouth.skin_match.contours.ih=polygon(500,750);
          console.log(JSON.stringify(['3d render','photograph','2d illustration',
            'unknown',null].map(medium=> {
              manifest.source_medium=medium;
              return !!stylizedMouthLipContour('ih',[400,700,200,100]);
            })));
        """)
        self.assertEqual([True, False, False, False, False], result)

    def test_registration_is_translation_not_scaling_or_mirroring(self):
        result = run_js("""
          manifest.stylized_mouth.skin_match.contours.ih=polygon(500,750);
          console.log(JSON.stringify(stylizedMouthLipContour('ih',
            [400,700,200,100],3)[0]));
        """)
        self.assertEqual([143, 50], result)

    def test_selected_expression_uses_its_own_viseme_and_strength(self):
        result = run_js("""
          const spec=manifest.stylized_mouth.skin_match;
          spec.contours.ih=polygon(500,750);
          spec.emotion_contours.horror={PP:[polygon(499,746),polygon(501,744)]};
          const atlas={visemes:['sil','PP'],emotions:['sorrow','horror']};
          console.log(JSON.stringify(stylizedMouthLipContour('ih',
            [400,700,200,100],2,atlas,{row:3,state:1})[0]));
        """)
        self.assertEqual([143, 44], result)

    def test_smile_atlas_has_implicit_smile_family(self):
        result = run_js("""
          manifest.stylized_mouth.skin_match.emotion_contours.smile={
            ih:[polygon(500,750),polygon(500,748)]};
          console.log(JSON.stringify(stylizedMouthLipContour('ih',
            [400,700,200,100],0,{visemes:['ih']},{row:0,state:1})[0]));
        """)
        self.assertEqual([140, 48], result)

    def test_missing_expression_geometry_does_not_fall_back_to_plain_lips(self):
        result = run_js("""
          manifest.stylized_mouth.skin_match.contours.ih=polygon(500,750);
          console.log(JSON.stringify(stylizedMouthLipContour('ih',
            [400,700,200,100],0,{visemes:['ih']},{row:0,state:1})));
        """)
        self.assertIsNone(result)

    def test_bad_or_unbounded_geometry_fails_closed(self):
        result = run_js("""
          const spec=manifest.stylized_mouth.skin_match;
          const candidates=[polygon(500,750),polygon(900,750),[[1,2]],
            polygon(500,750).map((p,i)=>i?p:[Infinity,750])];
          console.log(JSON.stringify(candidates.map(points=> {
            spec.contours.ih=points;
            return !!stylizedMouthLipContour('ih',[400,700,200,100]);
          })));
        """)
        self.assertEqual([True, False, False, False], result)

    def test_distance_inside_and_outside(self):
        result = run_js("""
          console.log(JSON.stringify([[100,50],[145,50],[100,30]].map(p=>
            stylizedMouthContourDistance(...p,polygon()))));
        """)
        self.assertEqual([0, 5, 5], result)

    def test_normalized_blur_retains_constant_fields_and_all_channels(self):
        result = run_js("""
          const width=20,height=10,values=new Float32Array(width*height*4);
          for(let i=0;i<values.length;i+=4) values.set([12,-7,4,1],i);
          const field=stylizedMouthBlurField(values,width,height,3);
          console.log(JSON.stringify(Array.from(field.slice(0,4))));
        """)
        self.assertEqual([12, -7, 4, 1], result)

    def test_spatial_skin_correction_fixes_opposite_side_lighting(self):
        result = run_js("""
          const f=fixture(x=>(x-100)*.18),before=f.source.slice();
          const applied=correctStylizedMouthSkin(f.source,f.neutral,
            f.width,f.height,f.contour,f.contour);
          let beforeError=0,afterError=0,count=0;
          for(let y=10;y<90;y++) for(let x=10;x<190;x++) {
            if(stylizedMouthContourDistance(x,y,f.contour)<25)continue;
            const i=(y*f.width+x)*4;
            for(let c=0;c<3;c++) {
              beforeError+=Math.abs(before[i+c]-f.neutral[i+c]);
              afterError+=Math.abs(f.source[i+c]-f.neutral[i+c]);count++;
            }
          }
          console.log(JSON.stringify({applied,ratio:afterError/beforeError,
            alpha:f.source.every((v,i)=>i%4!==3||v===before[i])}));
        """)
        self.assertTrue(result["applied"])
        self.assertLess(result["ratio"], .25)
        self.assertTrue(result["alpha"])

    def test_lips_teeth_and_antialias_fringe_are_byte_identical(self):
        result = run_js("""
          const f=fixture(x=>(x-100)*.18),before=f.source.slice();
          const applied=correctStylizedMouthSkin(f.source,f.neutral,
            f.width,f.height,f.contour,f.contour);
          let changed=0;
          for(let y=0;y<f.height;y++) for(let x=0;x<f.width;x++) {
            if(stylizedMouthContourDistance(x+.5,y+.5,f.contour)>14)continue;
            const i=(y*f.width+x)*4;
            for(let c=0;c<4;c++) changed+=f.source[i+c]!==before[i+c];
          }
          console.log(JSON.stringify({applied,changed}));
        """)
        self.assertEqual({"applied": True, "changed": 0}, result)

    def test_already_matched_or_legacy_better_state_is_not_modified(self):
        result = run_js("""
          console.log(JSON.stringify([0,3].map(offset=> {
            const f=fixture(()=>offset),before=f.source.slice();
            const applied=correctStylizedMouthSkin(f.source,f.neutral,
              f.width,f.height,f.contour,f.contour,[-offset,-offset,-offset]);
            return {applied,unchanged:f.source.every((v,i)=>v===before[i])};
          })));
        """)
        self.assertEqual([{"applied": False, "unchanged": True}] * 2, result)

    def test_insufficient_skin_is_a_no_op(self):
        result = run_js("""
          const f=fixture(()=>20);
          for(let i=3;i<f.source.length;i+=4)f.source[i]=128;
          const before=f.source.slice();
          const applied=correctStylizedMouthSkin(f.source,f.neutral,
            f.width,f.height,f.contour,f.contour);
          console.log(JSON.stringify({applied,
            unchanged:f.source.every((v,i)=>v===before[i])}));
        """)
        self.assertEqual({"applied": False, "unchanged": True}, result)

    def test_correction_is_bounded_and_never_changes_alpha(self):
        result = run_js("""
          const f=fixture(()=>65),before=f.source.slice();
          const applied=correctStylizedMouthSkin(f.source,f.neutral,
            f.width,f.height,f.contour,f.contour);
          console.log(JSON.stringify({applied,maximum:Math.max(...
            f.source.map((v,i)=>Math.abs(v-before[i]))),
            alpha:f.source.every((v,i)=>i%4!==3||v===before[i])}));
        """)
        self.assertTrue(result["applied"])
        self.assertLessEqual(result["maximum"], 48)
        self.assertTrue(result["alpha"])


if __name__ == "__main__":
    unittest.main()
