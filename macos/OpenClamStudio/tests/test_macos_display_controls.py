"""Exercise the actual Electron display functions without opening the app."""
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
NODE = shutil.which("node")


@unittest.skipUnless(NODE, "Node is required")
class MacDisplayControlsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main = (ROOT / "electron/main.cjs").read_text()
        names = ["rememberCurrentDisplayZoom", "restoreDisplayZoom", "standbyCompanionMode",
                 "restoreCompanionHold", "deskCompanionMode", "applyPetZoom", "applyPetZoomLive",
                 "petBoundsForZoom", "startupPetBounds", "activeAvatarWindow", "requestAvatarMotion",
                 "applyPetRoam", "stopPetRoamMotion", "dockBuddy"]
        cls.helpers = "\n".join(re.search(
            rf"function {name}\([^\n]*\) \{{[\s\S]*?\n\}}", cls.main)[0] for name in names)

    def run_js(self, assertions):
        bootstrap = r"""
          const assert=require('node:assert/strict');
          const {DISPLAY_ZOOM_DEFAULT,displayZoomKey,normalizeDisplayZooms,nativeEditMenuTemplate}
            =require('./electron/avatar-display-controls.cjs');
          const {fitPetWindowToArea,clampPetZoom,petZoomSize,dockedPetBounds,
            boundsForPetZoom,boundsForPetZoomAtAnchor,petZoomAnchor}
            =require('./electron/pet-window-bounds.cjs');
          const PET_BASE_SIZE={width:560,height:760}, PET_NORMAL_MINIMUM={width:140,height:190};
          const PET_ZOOM_RANGE={}, PET_ROAM_ZOOM_RANGE={min:.5,max:3}, PET_DOCK_MARGIN=28;
          let state={petZoom:.6,petDisplayZooms:normalizeDisplayZooms(null),petRoam:false,
            petOpacity:1,bounds:{x:100,y:150,width:336,height:456}};
          let chatMode=false,chatCloseUp=false,desktopCloseUp=false,chatCloseUpBaseZoom=.6;
          let chatPoseRevision=0,closeUpAnchorRevision=0,companionHold=null,preDockBounds=null,petZoomGesture=null;
          let writes=0,broadcasts=0,windowChanges=0;
          let windowBounds={...state.bounds};
          const mainWindow={isDestroyed:()=>false,getBounds:()=>({...windowBounds}),
            setBounds:b=>{windowBounds={...b};windowChanges++;},showInactive:()=>{},webContents:{id:1},
            setResizable:()=>{},setMinimumSize:()=>{}};
          const chatWindow={isDestroyed:()=>false,webContents:{id:2}};
          let buddyRoam=false;let buddyBounds={...windowBounds};
          const buddyWindow={isDestroyed:()=>false,getBounds:()=>({...buddyBounds}),
            setBounds:b=>{buddyBounds={...b};}};
          let area={x:0,y:25,width:1440,height:850};
          const screen={getDisplayMatching:()=>({workArea:area}),
            getDisplayNearestPoint:()=>({workArea:area}),getCursorScreenPoint:()=>({x:500,y:300})};
          const saveStateSoon=()=>{writes++;},broadcastState=()=>{broadcasts++;},pushAppearanceState=()=>{};
          const shellState=()=>({chatMode,chatCloseUp,desktopCloseUp,pet:{zoom:state.petZoom}});
          const applyPetOpacity=value=>{state.petOpacity=value;saveStateSoon();broadcastState();};
          let petMotionReady=true,petRoamTimer=null,petRoamRuntime=null,petRoamHoverGate=null,petDrag=null;
          const visibleBounds=b=>b,applyPetWindowLevel=()=>{},sendPetRoamMotion=()=>{};
          const startPetRoamMotion=()=>mainWindow.setBounds({x:800,y:600,width:150,height:204});
          const resizePetRoamWindow=()=>{};
          const createMainWindow=()=>mainWindow;
          const sent=[];const post=(owner,event,value)=>sent.push({owner,event,value});
        """
        result = subprocess.run([NODE, "-"], input=bootstrap + self.helpers + "\n" + assertions,
                                text=True, capture_output=True, cwd=ROOT, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_saved_zooms_are_finite_positive_independent_and_have_no_four_times_limit(self):
        self.run_js(r"""
          assert.deepEqual(normalizeDisplayZooms(null,1.3),{
            desktopStandby:1.3,desktopCloseUp:.6,chatStandby:1.3,chatCloseUp:.6});
          const raw={desktopStandby:Infinity,desktopCloseUp:-2,chatStandby:.1,chatCloseUp:9};
          assert.deepEqual(normalizeDisplayZooms(raw),{
            desktopStandby:.6,desktopCloseUp:.6,chatStandby:.1,chatCloseUp:9});
          const saved=normalizeDisplayZooms({desktopStandby:.8,desktopCloseUp:1.7,chatStandby:1.1,chatCloseUp:2.2});
          assert.deepEqual(normalizeDisplayZooms(JSON.parse(JSON.stringify(saved))),saved);
          assert.equal(displayZoomKey(true,false),'chatStandby');
          assert.equal(displayZoomKey(false,true),'desktopCloseUp');
          for(const zoom of [.0001,.08,4,16,256]) {
            const values=Object.fromEntries(['desktopStandby','desktopCloseUp','chatStandby','chatCloseUp']
              .map(key=>[key,zoom]));
            assert.deepEqual(normalizeDisplayZooms(JSON.parse(JSON.stringify(values))),values);
          }
        """)
        self.assertIn("const PET_ZOOM_RANGE = Object.freeze({});", self.main)

    def test_chat_shortcuts_keep_separate_sizes_reanchor_nine_and_survive_serialization(self):
        self.run_js(r"""
          chatMode=true;
          standbyCompanionMode();
          applyPetZoom(1.2);const beforeWindows=windowChanges;
          deskCompanionMode(); assert.equal(state.petZoom,.6);assert.equal(chatCloseUp,true);
          applyPetZoomLive({value:1.8,phase:'end'});
          standbyCompanionMode();assert.equal(state.petZoom,1.2);assert.equal(chatCloseUp,false);
          deskCompanionMode();assert.equal(state.petZoom,1.8);
          const revision=closeUpAnchorRevision;
          deskCompanionMode();assert.equal(state.petZoom,1.8);assert.equal(chatCloseUp,true);
          assert.equal(closeUpAnchorRevision,revision+1,'reselect9 is a position reset, never a size reset');
          assert.equal(windowChanges,beforeWindows,'chat presets never reveal/resize desktop avatar');
          const reopened=normalizeDisplayZooms(JSON.parse(JSON.stringify(state.petDisplayZooms)));
          assert.equal(reopened.chatStandby,1.2);assert.equal(reopened.chatCloseUp,1.8);
          assert.equal(reopened.desktopStandby,.6);assert.equal(reopened.desktopCloseUp,.6);
        """)

    def test_desktop_shortcuts_preserve_standby_geometry_and_only_camera_zoom_closeup(self):
        self.run_js(r"""
          standbyCompanionMode();
          applyPetZoom(.9);const standing={...windowBounds};
          deskCompanionMode();assert.equal(desktopCloseUp,true);
          assert.deepEqual(windowBounds,area);
          const fixedWindowCount=windowChanges;
          applyPetZoomLive({value:2.2,phase:'start'});applyPetZoomLive({value:2.4,phase:'end'});
          assert.equal(windowChanges,fixedWindowCount,'pinch in closeup cannot resize the screen canvas');
          assert.deepEqual(state.bounds,standing,'fullscreen canvas cannot replace saved standby bounds');
          deskCompanionMode();assert.equal(state.petZoom,2.4);assert.equal(companionHold.zoom,.9);
          standbyCompanionMode();assert.equal(state.petZoom,.9);assert.deepEqual(windowBounds,standing);
          deskCompanionMode();assert.equal(state.petZoom,2.4);
          assert.equal(state.petDisplayZooms.desktopStandby,.9);
          standbyCompanionMode();applyPetRoam(true);
          assert.equal(state.petRoam,true);assert.notDeepEqual(windowBounds,standing);
          standbyCompanionMode();assert.equal(state.petRoam,false);
          assert.equal(state.petZoom,.9);assert.deepEqual(windowBounds,standing);
          deskCompanionMode();assert.equal(state.petZoom,2.4);
        """)

    def test_canvas_switch_and_roam_do_not_overwrite_other_mode_memory(self):
        self.run_js(r"""
          applyPetZoom(1.1);deskCompanionMode();applyPetZoom(2);
          rememberCurrentDisplayZoom();restoreCompanionHold();desktopCloseUp=false;
          chatMode=true;restoreDisplayZoom(false);assert.equal(state.petZoom,.6);
          applyPetZoom(1.4);deskCompanionMode();applyPetZoom(.8);
          assert.deepEqual(state.petDisplayZooms,{
            desktopStandby:1.1,desktopCloseUp:2,chatStandby:1.4,chatCloseUp:.8});
          const saved=JSON.stringify(state.petDisplayZooms);
          state.petRoam=true;state.petZoom=3;rememberCurrentDisplayZoom();
          assert.equal(JSON.stringify(state.petDisplayZooms),saved);
        """)

    def test_zero_nine_sequence_remembers_sizes_beyond_both_old_limits_in_each_canvas(self):
        self.run_js(r"""
          for(const chat of [false,true]) {
            chatMode=chat;chatCloseUp=false;desktopCloseUp=false;companionHold=null;
            standbyCompanionMode();
            applyPetZoomLive({value:12,phase:'start'});
            applyPetZoomLive({value:16,phase:'end'});
            assert.equal(state.petZoom,16);
            const standing={...windowBounds};
            assert.ok(standing.width<=area.width&&standing.height<=area.height,
              'native window stays bounded independently of rendered zoom');
            deskCompanionMode();applyPetZoom(.08);
            assert.equal(state.petZoom,.08);
            standbyCompanionMode();assert.equal(state.petZoom,16);
            if(!chat)assert.deepEqual(windowBounds,standing);
            deskCompanionMode();assert.equal(state.petZoom,.08);
            const anchor=closeUpAnchorRevision;
            deskCompanionMode();assert.equal(state.petZoom,.08);
            assert.equal(closeUpAnchorRevision,anchor+1);
            const sizes=normalizeDisplayZooms(JSON.parse(JSON.stringify(state.petDisplayZooms)));
            assert.equal(sizes[displayZoomKey(chat,false)],16);
            assert.equal(sizes[displayZoomKey(chat,true)],.08);
            for(const bad of [NaN,Infinity,-Infinity,0,-2,undefined,Number.MAX_VALUE,Number.MIN_VALUE]) {
              applyPetZoomLive({value:bad,phase:'end'});assert.equal(state.petZoom,.08);
              applyPetZoom(bad);assert.equal(state.petZoom,.08);
            }
          }
        """)

    def test_native_startup_preserves_side_bottom_placement_and_zoom_on_small_displays(self):
        self.run_js(r"""
          area={x:-1920,y:30,width:1280,height:720};
          state.petDisplayZooms.desktopStandby=64;
          state.bounds={x:-3000,y:-800,width:2200,height:3000};
          const fit=startupPetBounds();
          assert.equal(state.petZoom,64);
          assert.equal(fit.x,-3000,'reopening does not redock an intentionally offscreen avatar');
          assert.equal(fit.y,area.y,'only the native top edge constrains placement');
          assert.ok(fit.width<=area.width&&fit.height<=area.height,
            'GPU backing size stays bounded independently of placement and rendered zoom');
          state.bounds={x:5000,y:4500,width:2200,height:3000};
          const below=startupPetBounds();
          assert.equal(below.x,5000);assert.equal(below.y,4500);
          assert.equal(state.petZoom,64);
          assert.ok(below.y>area.y+area.height,'the entire native canvas may be below the screen');
          for(const bad of [NaN,Infinity,-Infinity,undefined]){
            const b=fitPetWindowToArea({x:bad,y:bad,width:bad,height:bad},area);
            assert.ok(Object.values(b).every(Number.isFinite));
          }
        """)

    def test_manual_native_zoom_preserves_offscreen_anchor_without_side_or_bottom_cap(self):
        self.run_js(r"""
          for(const x of [-1e6,1e6]) for(const y of [-1e6,1e6]) {
            const original={x,y,width:336,height:456};
            windowBounds={...original};state.bounds={...original};state.petZoom=.6;
            state.petDisplayZooms=normalizeDisplayZooms(null,.6);
            const anchor=petZoomAnchor(original);
            applyPetZoomLive({value:12,phase:'start'});
            const enlarged={...windowBounds};
            assert.equal(state.petZoom,12,'native fitting does not cap the requested zoom');
            assert.ok(enlarged.width<=area.width&&enlarged.height<=area.height);
            assert.ok(Math.abs(enlarged.x+enlarged.width/2-anchor.x)<=.5,
              'fit the backing canvas around the saved gesture anchor, not a clamped screen edge');
            assert.equal(enlarged.y,Math.round(Math.max(area.y,anchor.y-enlarged.height/2)));
            if(x<0)assert.ok(enlarged.x+enlarged.width<area.x,'left overflow is deliberate');
            else assert.ok(enlarged.x>area.x+area.width,'right overflow is deliberate');
            if(y>0)assert.ok(enlarged.y>area.y+area.height,'bottom overflow is deliberate');
            applyPetZoomLive({value:6,phase:'move'});
            assert.equal(state.petZoom,6,'reverse pinch changes rendered zoom immediately beyond4x');
            assert.deepEqual(windowBounds,enlarged,'large zooms share a bounded native backing canvas');
            applyPetZoomLive({value:.6,phase:'end'});
            assert.equal(state.petZoom,.6);
            assert.deepEqual(windowBounds,{...original,y:Math.max(area.y,y)},
              'reversing the same gesture recovers position, except forbidden upward overflow');
            const memory=normalizeDisplayZooms(JSON.parse(JSON.stringify(state.petDisplayZooms)));
            assert.equal(memory.desktopStandby,.6);
            assert.equal(memory.desktopCloseUp,.6);
            assert.equal(memory.chatStandby,.6);
            assert.equal(memory.chatCloseUp,.6);
          }
        """)

    def test_closeup_and_temporary_motion_restore_intentional_offscreen_standby(self):
        self.run_js(r"""
          for(const x of [-1e6,1e6]) {
            const remembered={x,y:1e6,width:336,height:456};
            windowBounds={...remembered};state.bounds={...remembered};state.petZoom=.6;
            state.petDisplayZooms=normalizeDisplayZooms(null,.6);
            standbyCompanionMode();deskCompanionMode();
            assert.deepEqual(windowBounds,area,'Close-up keeps its normal display-sized canvas');
            applyPetZoom(16);
            standbyCompanionMode();
            assert.deepEqual(windowBounds,remembered,
              'returning from Close-up must not redock saved side/bottom overflow');
            assert.equal(state.petZoom,.6);
            assert.equal(state.petDisplayZooms.desktopCloseUp,16);
            applyPetRoam(true);
            assert.notDeepEqual(windowBounds,remembered);
            standbyCompanionMode();
            assert.deepEqual(windowBounds,remembered,
              'returning from an automatic motion must restore the manual offscreen pose');
            assert.equal(state.petZoom,.6);
            assert.equal(state.petDisplayZooms.desktopCloseUp,16);
            assert.equal(state.petHomeBounds,null);
          }
        """)

    def test_second_avatar_dock_keeps_native_canvas_bounded_without_limiting_zoom(self):
        self.run_js(r"""
          state.petZoom=64;dockBuddy();
          assert.equal(state.petZoom,64);
          assert.ok(buddyBounds.x>=area.x&&buddyBounds.y>=area.y);
          assert.ok(buddyBounds.x+buddyBounds.width<=area.x+area.width);
          assert.ok(buddyBounds.y+buddyBounds.height<=area.y+area.height);
        """)

    def test_motion_menu_dispatches_only_to_visible_owner_with_allowlisted_modes(self):
        self.run_js(r"""
          requestAvatarMotion('idle');chatMode=true;requestAvatarMotion('moves');requestAvatarMotion('walk');
          requestAvatarMotion('arbitrary-code');
          assert.equal(sent.length,3);assert.equal(sent[0].owner,mainWindow);
          assert.equal(sent[1].owner,chatWindow);assert.equal(sent[2].owner,chatWindow);
          assert.equal(sent[1].event,'openclam:display-mode-request');
          assert.equal(sent[1].value,'moves');
        """)

    def test_native_text_menu_uses_standard_roles_and_never_requires_clipboard_read(self):
        self.run_js(r"""
          assert.equal(nativeEditMenuTemplate({isEditable:false}),null);
          const menu=nativeEditMenuTemplate({isEditable:true,editFlags:{
            canUndo:true,canRedo:false,canCopy:true,canCut:true,canPaste:true,canSelectAll:true}});
          assert.deepEqual(menu.filter(item=>item.role).map(item=>item.role),
            ['undo','redo','cut','copy','paste','pasteAndMatchStyle','selectAll']);
          assert.equal(menu.find(item=>item.role==='redo').enabled,false);
          assert.equal(menu.find(item=>item.role==='paste').enabled,true);
        """)
        self.assertIn("nativeEditMenuTemplate(params)", self.main)
        self.assertIn("Menu.buildFromTemplate(template).popup({ window })", self.main)

    def test_appearance_first_state_is_not_mistaken_for_a_recent_slider_edit(self):
        source = (ROOT / "web/appearance.html").read_text()
        helpers = "\n".join([
            re.search(r"let holding=null,editedAt=[^;]+;", source)[0],
            re.search(r"const engaged=input=>[^;]+;", source)[0],
            re.search(r"function sizeRange\(control,value\)\{[\s\S]*?\n    \}", source)[0],
            re.search(r"function adopt\(control,value\)\{[\s\S]*?\n    \}", source)[0],
        ])
        script = r"""
          const assert=require('node:assert/strict');
          let now=10;const performance={now:()=>now};const show=()=>{};
          const control={input:{min:'25',max:'400',value:'100'}};
        """ + helpers + r"""
          adopt(control,60);assert.equal(control.input.value,'60',
            'initial IPC must replace HTML defaults even before 420ms');
          editedAt=now;control.input.value='135';adopt(control,60);
          assert.equal(control.input.value,'135','real recent edits retain their value');
          now+=421;adopt(control,60);assert.equal(control.input.value,'60');
          holding=control.input;adopt(control,90);assert.equal(control.input.value,'60');
          holding=null;editedAt=-Infinity;adopt(control,90);assert.equal(control.input.value,'90');
        """
        result = subprocess.run([NODE, "-"], input=script, text=True, capture_output=True,
                                cwd=ROOT, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(source.count("holding=null;editedAt=-Infinity;"), 3)

    def test_appearance_size_range_preserves_pinch_values_and_keeps_extending(self):
        source=(ROOT / "web/appearance.html").read_text()
        helpers="\n".join([
            re.search(r"function sizeRange\(control,value\)\{[\s\S]*?\n    \}", source)[0],
            re.search(r"function adopt\(control,value\)\{[\s\S]*?\n    \}", source)[0],
        ])
        script=r"""
          const assert=require('node:assert/strict');
          let editing=false;const engaged=()=>editing,show=()=>{};
          const input={min:'25',max:'400',_value:'100'};
          // Like a native range input, assigning outside min/max clamps it.
          Object.defineProperty(input,'value',{
            get(){return this._value;},
            set(v){this._value=String(Math.max(Number(this.min),Math.min(Number(this.max),Number(v))));}
          });
          const control={input,scalable:true};
        """+helpers+r"""
          for(const percent of [8.125,25,60,400,1600.75,25600]) {
            adopt(control,percent);
            assert.equal(Number(input.value),percent,'opening appearance cannot roundtrip-clamp size');
            assert.ok(Number(input.min)<percent && Number(input.max)>percent,
              'editing window has room both directions');
          }
          for(let attempt=0;attempt<8;attempt++) {
            const oldMax=Number(input.max);input.value=String(oldMax);
            sizeRange(control,oldMax);
            assert.ok(Number(input.max)>oldMax,'reaching slider end opens more range');
            assert.equal(Number(input.value),oldMax);
          }
          const held=input.value;editing=true;adopt(control,60);
          assert.equal(input.value,held,'external state never fights an active slider');
          editing=false;adopt(control,8);assert.equal(input.value,'8');
          assert.ok(Number(input.min)<8);
        """
        result=subprocess.run([NODE,"-"],input=script,text=True,capture_output=True,cwd=ROOT,timeout=20)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('id="size" type="range" min="25" max="400" step="any"',source)

    def test_shortcut_routes_and_text_popover_theme_are_consistent(self):
        self.assertRegex(self.main, r"globalShortcut\.register\(accelerator, standbyCompanionMode\)")
        self.assertRegex(self.main, r"input\.key === '0'[\s\S]{0,150}standbyCompanionMode\(\)")
        web = (ROOT / "web/index.html").read_text()
        selections = re.findall(r"#selectionActions \{([^}]+)\}", web)
        for style in selections:
            if "background:" in style:
                self.assertIn("background: var(--codex-surface-raised)", style)
        self.assertIn(".selection-action { color: var(--codex-text); }", web)
        self.assertIn("canvas.addEventListener('contextmenu', showAvatarContextMenu)", web)

    def test_avatar_context_menu_supports_both_layers_without_stealing_text_or_controls(self):
        web = (ROOT / "web/index.html").read_text()
        helper = re.search(r"    (const showAvatarContextMenu =[\s\S]*?\n    \};)", web)[1]
        script = r"""
          const assert=require('node:assert/strict');
          let painted=true,calls=0,selected=false;
          const paintedAvatarAt=()=>painted,shell={showPetMenu:()=>{calls++;}};
          const getSelection=()=>({isCollapsed:!selected,toString:()=>selected?'chosen text':''});
          const event=(blocked=false)=>({defaultPrevented:false,clientX:40,clientY:60,
            target:{closest:()=>blocked?{}:null},
            preventDefault(){this.defaultPrevented=true;},stopPropagation(){this.stopped=true;}});
        """ + helper + r"""
          for (const layer of ['avatar','thread']) {
            const e=event();assert.equal(showAvatarContextMenu(e),true);
            assert.equal(e.defaultPrevented,true);assert.equal(e.stopped,true);
          }
          selected=true;assert.equal(showAvatarContextMenu(event()),false);
          selected=false;assert.equal(showAvatarContextMenu(event(true)),false);
          painted=false;assert.equal(showAvatarContextMenu(event()),false);
          painted=true;const handled=event();handled.defaultPrevented=true;
          assert.equal(showAvatarContextMenu(handled),false);assert.equal(calls,2);
        """
        result = subprocess.run([NODE, "-"], input=script, text=True, capture_output=True,
                                cwd=ROOT, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(web, r"document.addEventListener\('contextmenu',[\s\S]{0,160}chatWorkspace.contains\(event.target\)[\s\S]{0,100}showAvatarContextMenu\(event\)")
        self.assertIn("#composerShell", helper)


if __name__ == "__main__":
    unittest.main()
