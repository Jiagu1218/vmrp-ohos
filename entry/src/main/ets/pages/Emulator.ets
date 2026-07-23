import { abilityAccessCtrl } from '@kit.AbilityKit';
import { NodeContent, ComponentContent, AppStorageV2, display } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import {
  HdsNavDestination, ScrollEffectType, hdsMaterial
} from '@kit.UIDesignKit';
import {
  VmrpEngineTs, VMRP_KEY_PRESS, VMRP_KEY_RELEASE
} from '../vmrp/VmrpEngine';
import { VmrpAssets } from '../vmrp/VmrpAssets';
import { gAbilityContext } from '../entryability/EntryAbility';
import { AvoidData } from '../common/AvoidData';
import { HapticManager } from '../common/HapticManager';
import { ImmersiveLightWrapper } from '../common/ImmersiveLightWrapper';
import { GlassPanel } from '../common/GlassPanel';
import { GpBinding, defaultBindings as defaultGpBindings, jsonToBindings as gpJsonToBindings } from '../components/GamepadBinding';
import { keyCodeToSrc, computeStickDirections } from '../components/GamepadHelpers';
import {
  DPadBtn, SoftKeyBtn, DPadWithFunc, NumPad, TopScreen, StatusBarChip,
  BottomControls, PhoneControls, EditDialogContent, EditDialogContentBuilder,
  ScreenShellParam, EditDialogContentBuilderParams, EditDialogOptions,
  SCREEN_BG, DPAD_ARROW, NUMKEY_TEXT, NUMKEY_BG, RUN_DOT, SHELL_BORDER, ACCENT_COLOR, STATUS_TEXT
} from '../components/EmulatorControls';

interface GridRowColumns {
  sm: number;
  md: number;
  lg: number;
}

interface GridRowGutter {
  x: number;
  y: number;
}

interface GridColSpan {
  sm: number;
  md: number;
  lg: number;
}

interface GridRowBreakpoints {
  value: string[];
  reference: BreakpointsReference;
}

@ComponentV2
struct EmulatorPage {
  @Local statusText: string = '未启动';
  @Local runningState: boolean = false;
  @Local screenVisible: boolean = true;
  @Local editText: string = '';
  @Local currentBp: string = 'sm';
  @Local showControls: boolean = true;
  @Local showNumPadVal: boolean = true;
  @Local isFoldable: boolean = false;
  @Local foldStatus: display.FoldStatus = display.FoldStatus.FOLD_STATUS_UNKNOWN;
  @Local screenAreaW: number = 240;
  @Local screenAreaH: number = 320;
  @Local bufW: number = 240;
  @Local bufH: number = 320;
  @Local dualAreaW: number = 400;
  @Local dualAreaH: number = 600;
  @Local speedMultiplier: number = 1;
  @Local gamepadConnected: boolean = false;
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
  private navPathStack: NavPathStack = new NavPathStack();
  private engine: VmrpEngineTs = new VmrpEngineTs();
  private pressedKeys: Set<number> = new Set();
  private gpBindings: GpBinding[] = defaultGpBindings();
  private srcToMrKeys: Map<string, number[]> = new Map();
  private stickAxes: Map<AxisModel, number> = new Map();
  private stickPressedKeys: Set<number> = new Set();
  private nodeContent: NodeContent = new NodeContent();
  private mrpPath: string = '';
  private gridColumns: GridRowColumns = { sm: 1, md: 2, lg: 2 };
  private gridGutter: GridRowGutter = { x: 8, y: 6 };
  private gridBreakpoints: GridRowBreakpoints = {
    value: ['520vp', '840vp'],
    reference: BreakpointsReference.WindowSize
  };
  private topSpan: GridColSpan = { sm: 12, md: 6, lg: 6 };
  private bottomSpan: GridColSpan = { sm: 12, md: 6, lg: 6 };

  aboutToAppear(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const wVP = this.getUIContext().px2vp(d.width);
      const hVP = this.getUIContext().px2vp(d.height);
      this.isFoldable = display.isFoldable();
      if (this.isFoldable) {
        this.foldStatus = display.getFoldStatus();
      }
      if (wVP >= 840) {
        this.currentBp = 'lg';
      } else if (wVP >= 520) {
        this.currentBp = 'md';
      } else {
        this.currentBp = 'sm';
      }
      this.screenAreaW = wVP;
      this.screenAreaH = hVP;
      this.dualAreaW = wVP / 2 - 4;
      this.dualAreaH = hVP;
      if (this.isFoldable) {
        display.on('foldStatusChange', (status: display.FoldStatus) => {
          this.foldStatus = status;
        });
      }
    } catch (_e) {
      this.currentBp = 'sm';
    }
    this.bootstrap();
  }

  aboutToDisappear(): void {
    try {
      this.engine.stop();
    } catch (_e) {}
  }

  async bootstrap(): Promise<void> {
    try {
      this.statusText = '正在加载...';
      await this.engine.init();
      const ctx = gAbilityContext ?? this.getUIContext().getHostContext();
      if (!ctx) {
        this.statusText = '初始化失败';
        return;
      }
      this.statusText = '准备资源...';
      const workDir = await VmrpAssets.ensureRuntime(ctx);
      let ok = this.engine.loadLib('libvmrp.so');
      if (!ok) {
        ok = this.engine.loadLib(`${ctx.bundleCodeDir}/lib/arm64/libvmrp.so`);
      }
      if (!ok) {
        this.statusText = '加载失败';
        return;
      }
      this.engine.setScreen(240, 320);
      try {
        const pref = await preferences.getPreferences(ctx, 'vmrp_settings');
        const screenW = (await pref.get('screen_width', 240)) as number;
        const screenH = (await pref.get('screen_height', 320)) as number;
        if (screenW > 0 && screenH > 0) {
          this.engine.setScreen(screenW, screenH);
          this.bufW = screenW;
          this.bufH = screenH;
        }
        const mem = (await pref.get('memory_mb', 1)) as number;
        this.engine.setMemory(mem);
        const sensitivity = (await pref.get('motion_sensitivity', 1.0)) as number;
        this.engine.setMotionSensitivity(sensitivity);
        const shakeIntensity = (await pref.get('shake_intensity', 1)) as number;
        this.engine.setShakeIntensity(shakeIntensity);
        const displayFilter = (await pref.get('display_filter', 0)) as number;
        const screenEffect = (await pref.get('screen_effect', 0)) as number;
        const screenEffectStrength = (await pref.get('screen_effect_strength', 0.5)) as number;
        const brightness = (await pref.get('brightness', 0.0)) as number;
        const contrast = (await pref.get('contrast', 1.0)) as number;
        const saturation = (await pref.get('saturation', 1.0)) as number;
        const subpixelRender = (await pref.get('subpixel_render', 0)) as number;
        const gammaCorrect = (await pref.get('gamma_correct', 1)) as number;
        const dither = (await pref.get('dither', 1)) as number;
        this.engine.setDisplayFilter(displayFilter, screenEffect, screenEffectStrength,
          brightness, contrast, saturation, subpixelRender, gammaCorrect, dither);
        const speedMult = (await pref.get('speed_multiplier', 1)) as number;
        if (speedMult >= 1 && speedMult <= 4) {
          this.speedMultiplier = speedMult;
          this.engine.setSpeedMultiplier(speedMult);
        }
        const gamepadBindings = (await pref.get('gamepad_bindings', '')) as string;
        this.applyGpBindings(gamepadBindings);
        await HapticManager.loadPref(ctx);
      } catch (_e) {
      }
      try {
        const atManager = abilityAccessCtrl.createAtManager();
        await atManager.requestPermissionsFromUser(ctx, ['ohos.permission.ACCELEROMETER']);
      } catch (_e) {
      }
      this.engine.setWorkDir(workDir);
      this.engine.setEditCallback((editText: string) => {
        this.editText = editText;
        this.openEditDialog();
      });
      this.engine.setExitCallback(() => {
        this.runningState = false;
        this.screenVisible = false;
        try { this.engine.stop(); } catch (_e) {}
        this.navPathStack.pop();
      });
      this.engine.createSurfaceNode(this.nodeContent);
      this.statusText = '启动中...';
      await this.startMrp();
    } catch (e) {
      const err = e as Error;
      this.statusText = `失败: ${err?.message ?? String(e)}`;
    }
  }

  private openEditDialog(): void {
    const uiCtx = this.getUIContext();
    const prompt = uiCtx.getPromptAction();
    const params: EditDialogContentBuilderParams = {
      editText: this.editText,
      onTextChange: (_v: string) => {},
      onSubmit: (t: string) => {
        this.engine.submitEdit(t);
        prompt.closeCustomDialog(contentNode);
      },
      onCancel: () => {
        this.engine.cancelEdit();
        prompt.closeCustomDialog(contentNode);
      }
    };
    const contentNode = new ComponentContent(uiCtx, wrapBuilder(EditDialogContentBuilder), params);
    const opts: EditDialogOptions = {
      alignment: DialogAlignment.Center,
      autoCancel: false
    };
    prompt.openCustomDialog(contentNode, opts);
  }

  async startMrp(): Promise<void> {
    if (this.mrpPath.length === 0) {
      this.statusText = '未指定 MRP';
      return;
    }
    try {
      const r = this.engine.start(this.mrpPath, 'start.mr', '_dsm');
      this.runningState = this.engine.isRunning();
      this.statusText = `${r}, ${this.runningState ? '运行中' : '已停止'}`;
    } catch (e) {
      const err = e as Error;
      this.statusText = `失败: ${err?.message ?? String(e)}`;
    }
  }

  onKeyTouch(key: number, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (!this.pressedKeys.has(key)) {
        this.pressedKeys.add(key);
        this.engine.sendKey(VMRP_KEY_PRESS, key);
        HapticManager.performClick();
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.pressedKeys.has(key)) {
        this.pressedKeys.delete(key);
        this.engine.sendKey(VMRP_KEY_RELEASE, key);
      }
    }
  }

  private rebuildSrcMap(): void {
    this.srcToMrKeys = new Map();
    for (const b of this.gpBindings) {
      this.srcToMrKeys.set(b.src, b.mrKeys);
    }
  }

  private onGamepadKeyEvent(event: KeyEvent): void {
    const src = keyCodeToSrc(event.keyCode);
    if (src.length === 0) return;
    const mrKeys = this.srcToMrKeys.get(src);
    if (mrKeys === undefined || mrKeys.length === 0) return;
    if (event.type === KeyType.Down) {
      this.gamepadConnected = true;
      for (const k of mrKeys) {
        if (!this.pressedKeys.has(k)) {
          this.pressedKeys.add(k);
          this.engine.sendKey(VMRP_KEY_PRESS, k);
        }
      }
      HapticManager.performClick();
    } else if (event.type === KeyType.Up) {
      for (const k of mrKeys) {
        if (this.pressedKeys.has(k)) {
          this.pressedKeys.delete(k);
          this.engine.sendKey(VMRP_KEY_RELEASE, k);
        }
      }
    }
  }

  private updateStickDirection(): void {
    const lx = this.stickAxes.get(AxisModel.ABS_X) ?? 0;
    const ly = this.stickAxes.get(AxisModel.ABS_Y) ?? 0;
    const rx = this.stickAxes.get(AxisModel.ABS_RZ) ?? 0;
    const ry = this.stickAxes.get(AxisModel.ABS_Z) ?? 0;
    const hatX = this.stickAxes.get(AxisModel.ABS_HAT0X) ?? 0;
    const hatY = this.stickAxes.get(AxisModel.ABS_HAT0Y) ?? 0;

    const lDirs = computeStickDirections(lx, ly);
    const rDirs = computeStickDirections(rx, ry);
    const hatDirs = computeStickDirections(hatX, hatY);

    const newPressed: Set<number> = new Set();
    const allDirs: string[] = [...lDirs, ...rDirs, ...hatDirs];
    for (const dir of allDirs) {
      const lSrc = `stick_l_${dir}`;
      const rSrc = `stick_r_${dir}`;
      const hatSrc = `dpad_${dir}`;
      for (const src of [lSrc, rSrc, hatSrc]) {
        const mrKeys = this.srcToMrKeys.get(src);
        if (mrKeys !== undefined) {
          for (const k of mrKeys) {
            newPressed.add(k);
          }
        }
      }
    }

    const toRelease: number[] = [];
    this.stickPressedKeys.forEach((key: number) => {
      if (!newPressed.has(key)) toRelease.push(key);
    });
    const toPress: number[] = [];
    newPressed.forEach((key: number) => {
      if (!this.stickPressedKeys.has(key) && !this.pressedKeys.has(key)) toPress.push(key);
    });

    for (const key of toRelease) {
      this.stickPressedKeys.delete(key);
      this.engine.sendKey(VMRP_KEY_RELEASE, key);
    }
    for (const key of toPress) {
      this.stickPressedKeys.add(key);
      this.engine.sendKey(VMRP_KEY_PRESS, key);
    }
  }

  private onGamepadAxisEvent(event: FocusAxisEvent): void {
    const keys: AxisModel[] = [
      AxisModel.ABS_X, AxisModel.ABS_Y, AxisModel.ABS_Z, AxisModel.ABS_RZ,
      AxisModel.ABS_HAT0X, AxisModel.ABS_HAT0Y
    ];
    let changed = false;
    for (const k of keys) {
      const val = event.axisMap.get(k);
      if (val !== undefined) {
        this.stickAxes.set(k, val);
        changed = true;
      }
    }
    if (changed) {
      this.gamepadConnected = true;
      this.updateStickDirection();
    }
  }

  private applyGpBindings(bindingsJson: string): void {
    if (bindingsJson.length > 0) {
      try {
        this.gpBindings = gpJsonToBindings(bindingsJson);
      } catch (_e) {
        this.gpBindings = defaultGpBindings();
      }
    } else {
      this.gpBindings = defaultGpBindings();
    }
    this.rebuildSrcMap();
  }

  @Builder
  screenShell($$: ScreenShellParam) {
    Column() {
      if ($$.isTop) {
        TopScreen({
          nodeContent: this.nodeContent,
          statusText: this.statusText,
          runningState: this.runningState,
          scaleVal: this.currentBp === 'sm' ? 1 : Math.min((this.dualAreaW - 24) / this.bufW, (this.dualAreaH * 0.5 - 36) / this.bufH),
          bufW: this.bufW,
          bufH: this.bufH,
          screenVisible: this.screenVisible,
          speedMultiplier: this.speedMultiplier,
          onSpeedChange: (mult: number) => {
            this.speedMultiplier = mult;
            this.engine.setSpeedMultiplier(mult);
          }
        })
      } else {
        Scroll() {
          Column() {
            BottomControls({
              onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e),
              runningState: this.runningState,
              dpadSizeVal: this.currentBp === 'sm' ? 110 : Math.min((this.dualAreaW - 24) * 0.4, 130),
              btnSizeVal: this.currentBp === 'sm' ? 30 : Math.min((this.dualAreaW - 24) * 0.1, 36),
              showNumPadVal: this.showNumPadVal
            })
          }
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  phoneLayout() {
    Column() {
      Stack() {
           Stack() {
             if (this.screenVisible) {
               ContentSlot(this.nodeContent)
             }
           }
           .width(this.bufW)
           .height(this.bufH)
           .backgroundColor(SCREEN_BG)
        .scale({
          x: Math.min(this.screenAreaW / this.bufW, this.screenAreaH / this.bufH),
          y: Math.min(this.screenAreaW / this.bufW, this.screenAreaH / this.bufH)
        })
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.Center)
      .clip(true)
      .onAreaChange((_old: Area, newVal: Area) => {
        this.screenAreaW = newVal.width as number;
        this.screenAreaH = newVal.height as number;
      })

      Row() {
        Row()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.runningState ? RUN_DOT : '#555577')
          .margin({ right: 6 })
        Text(this.statusText)
          .fontSize(10)
          .fontColor(STATUS_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
         StatusBarChip({
           chipLabel: `${this.speedMultiplier}x`,
           chipFontColor: this.speedMultiplier > 1 ? $r('app.color.accent_color') : DPAD_ARROW,
           onChipClick: () => {
             const next = this.speedMultiplier >= 4 ? 1 : this.speedMultiplier + 1;
             this.speedMultiplier = next;
             this.engine.setSpeedMultiplier(next);
           }
         })
         if (this.gamepadConnected) {
           StatusBarChip({ chipLabel: '🎮', chipFontColor: RUN_DOT })
         }
         StatusBarChip({ chipLabel: '设置', onChipClick: () => this.navPathStack.pushPathByName('Settings', null) })
        StatusBarChip({
          chipLabel: '数字',
          chipFontColor: this.showNumPadVal ? DPAD_ARROW : NUMKEY_TEXT,
          onChipClick: () => { this.showNumPadVal = !this.showNumPadVal; }
        })
        StatusBarChip({
          chipLabel: this.showControls ? '收起' : '按键',
          chipFontColor: DPAD_ARROW,
          onChipClick: () => { this.showControls = !this.showControls; }
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })

      if (this.showControls) {
        Column() {
          GlassPanel({
            blurRadius: 30,
            panelBorderRadius: 16,
            panelBorderColor: SHELL_BORDER,
            panelBgColor: '#0A0A1ECC',
            panelBorderWidth: 1
          }) {
            Scroll() {
              Column() {
                PhoneControls({
                  onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e),
                  runningState: this.runningState,
                  showNumPadVal: this.showNumPadVal
                })
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
            }
            .constraintSize({ maxHeight: '46%' })
            .width('100%')
            .scrollBar(BarState.Off)
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.avoidData.bottomVp })
  }

  @Builder
  foldExpandedLayout() {
    Column() {
      Column() {
         Stack() {
           Stack() {
             if (this.screenVisible) {
               ContentSlot(this.nodeContent)
             }
           }
           .width(this.bufW)
           .height(this.bufH)
           .backgroundColor(SCREEN_BG)
           .borderRadius(6)
           .clip(true)
          .scale({
            x: Math.min(this.screenAreaW / this.bufW, this.screenAreaH * 0.48 / this.bufH),
            y: Math.min(this.screenAreaW / this.bufW, this.screenAreaH * 0.48 / this.bufH)
          })
          .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
        }
        .width('100%')
        .height('50%')
        .alignContent(Alignment.Center)

        Row() {
          Row()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.runningState ? RUN_DOT : '#555577')
            .margin({ right: 6 })
          Text(this.statusText)
            .fontSize(10)
            .fontColor(STATUS_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
         StatusBarChip({
           chipLabel: `${this.speedMultiplier}x`,
           chipFontColor: this.speedMultiplier > 1 ? $r('app.color.accent_color') : DPAD_ARROW,
           onChipClick: () => {
             const next = this.speedMultiplier >= 4 ? 1 : this.speedMultiplier + 1;
             this.speedMultiplier = next;
             this.engine.setSpeedMultiplier(next);
           }
         })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      }
      .width('100%')
      .height('50%')
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .onAreaChange((_old: Area, newVal: Area) => {
        this.screenAreaW = newVal.width as number;
        this.screenAreaH = newVal.height as number;
      })

      Column() {
        GlassPanel({
          blurRadius: 30,
          panelBorderRadius: 16,
          panelBorderColor: SHELL_BORDER,
          panelBgColor: '#0A0A1ECC',
          panelBorderWidth: 1
        }) {
          Scroll() {
            Column() {
              Row() {
                DPadWithFunc({ onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e), dpadSize: Math.min(this.screenAreaW * 0.22, 120) })

                if (this.showNumPadVal) {
                  NumPad({ onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e), btnSizeVal: Math.min(this.screenAreaW * 0.07, 34) })
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)

              Row({ space: 8 }) {
                Column() {
                  ImmersiveLightWrapper({ radius: 13, lightHeight: 80 }) {
                    Stack() {
                      Text(this.showNumPadVal ? '收起数字' : '数字')
                        .fontSize(11)
                        .fontColor(this.showNumPadVal ? DPAD_ARROW : '#CCCCCC')
                    }
                    .height(26)
                    .padding({ left: 14, right: 14 })
                    .backgroundColor(Color.Transparent)
                  }
                }
                .onClick(() => { HapticManager.performClick(); this.showNumPadVal = !this.showNumPadVal; })
              }
              .padding({ top: 4, bottom: 4 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  dualScreenLayout() {
    GridRow({
      columns: this.gridColumns,
      gutter: this.gridGutter,
      breakpoints: this.gridBreakpoints
    }) {
      GridCol({ span: this.topSpan }) {
        Column() {
          Column() {
            GlassPanel({
              blurRadius: 20,
              panelBorderRadius: 16,
              panelBorderColor: SHELL_BORDER,
              panelBgColor: '#0A0A1ECC',
              panelBorderWidth: 1
            }) {
              this.screenShell({ isTop: true })
            }
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height('100%')
      }
      .height('100%')

      GridCol({ span: this.bottomSpan }) {
        Column() {
          Column() {
            GlassPanel({
              blurRadius: 20,
              panelBorderRadius: 16,
              panelBorderColor: SHELL_BORDER,
              panelBgColor: '#0A0A1ECC',
              panelBorderWidth: 1
            }) {
              this.screenShell({ isTop: false })
            }
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height('100%')
      }
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .onBreakpointChange((bp: string) => {
      this.currentBp = bp;
    })
    .onAreaChange((_old: Area, newVal: Area) => {
      this.dualAreaW = (newVal.width as number) / 2 - 4;
      this.dualAreaH = newVal.height as number;
    })
  }

  build() {
    HdsNavDestination() {
      Column() {
        if (this.isFoldable && (this.foldStatus === display.FoldStatus.FOLD_STATUS_EXPANDED ||
          this.foldStatus === display.FoldStatus.FOLD_STATUS_HALF_FOLDED)) {
          this.foldExpandedLayout()
        } else if (this.currentBp === 'sm') {
          this.phoneLayout()
        } else {
          this.dualScreenLayout()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0D0D1A')
      .focusScopeId('emulatorGroup', true, false)
      .defaultFocus(true)
      .onKeyEvent((event: KeyEvent) => {
        this.onGamepadKeyEvent(event);
      })
      .onFocusAxisEvent((event: FocusAxisEvent) => {
        this.onGamepadAxisEvent(event);
      })
    }
    .backgroundColor($r('app.color.immersive_bg'))
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.SLIDE_BOTTOM)
    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
      this.mrpPath = context.pathInfo.param as string;
    })
    .onWillDisappear(() => {
      this.screenVisible = false;
      try { this.engine.stop(); } catch (_e) {}
    })
  }
}

@Builder
export function EmulatorBuilder() {
  EmulatorPage()
}
