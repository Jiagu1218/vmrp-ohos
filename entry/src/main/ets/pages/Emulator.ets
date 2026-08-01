import { abilityAccessCtrl } from '@kit.AbilityKit';
import { NodeContent, ComponentContent, AppStorageV2, display } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import {
  HdsNavDestination
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
  DPadWithFunc, NumPad, TopScreen, StatusBarChip,
  PhoneControls, EditDialogContent, EditDialogContentBuilder,
  EditDialogContentBuilderParams, EditDialogOptions,
  SCREEN_BG, DPAD_ARROW, NUMKEY_TEXT, RUN_DOT, SHELL_BORDER, STATUS_TEXT
} from '../components/EmulatorControls';

@ComponentV2
struct EmulatorPage {
  @Local statusText: string = '';
  @Local runningState: boolean = false;
  @Local engineMode: string = '';  // "JIT" / "TCI" / ""
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
  @Local isLandscape: boolean = false;
  @Local leftColW: number = 200;
  @Local midColW: number = 400;
  @Local midColH: number = 600;
  @Local rightColW: number = 200;
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


  aboutToAppear(): void {
    this.statusText = '';
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
      this.isLandscape = wVP > hVP;
      this.leftColW = wVP * 0.25;
      this.midColW = wVP * 0.5;
      this.midColH = hVP;
      this.rightColW = wVP * 0.25;
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
      this.statusText = 'Loading...';
      await this.engine.init();
      const ctx = gAbilityContext ?? this.getUIContext().getHostContext();
      if (!ctx) {
        this.statusText = 'Init failed';
        return;
      }
      this.statusText = 'Preparing...';
      const workDir = await VmrpAssets.ensureRuntime(ctx);
      let ok = this.engine.loadLib('libvmrp.so');
      if (!ok) {
        ok = this.engine.loadLib(`${ctx.bundleCodeDir}/lib/arm64/libvmrp.so`);
      }
      if (!ok) {
        this.statusText = 'Load failed';
        return;
      }
      this.engineMode = this.engine.getEngineMode();
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
      this.statusText = 'Starting...';
       await this.startMrp();
     } catch (e) {
       const err = e as Error;
        this.statusText = `Failed: ${err?.message ?? String(e)}`;
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
      this.statusText = 'No MRP';
      return;
    }
    try {
      const r = this.engine.start(this.mrpPath, 'start.mr', '_dsm');
      this.runningState = this.engine.isRunning();
      this.statusText = `${r}, ${this.runningState ? 'Running' : 'Stopped'}` +
        (this.engineMode.length > 0 ? ` · ${this.engineMode}` : '');
    } catch (e) {
      const err = e as Error;
      this.statusText = `Failed: ${err?.message ?? String(e)}`;
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
  tabletLandscapeLayout() {
    Row() {
      Column() {
        DPadWithFunc({
          onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e),
          dpadSize: Math.min(this.leftColW * 0.55, 170),
          softKeyH: 32
        })

        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
          StatusBarChip({
            chipLabel: `${this.speedMultiplier}x`,
            chipFontColor: this.speedMultiplier > 1 ? $r('app.color.accent_color') : DPAD_ARROW,
            onChipClick: () => {
              const next = this.speedMultiplier >= 4 ? 1 : this.speedMultiplier + 1;
              this.speedMultiplier = next;
              this.engine.setSpeedMultiplier(next);
            }
          }).margin(3)
          StatusBarChip({
            chipLabel: $r('app.string.emulator_chip_settings'),
            onChipClick: () => this.navPathStack.pushPathByName('Settings', null)
          }).margin(3)
          StatusBarChip({
            chipLabel: $r('app.string.emulator_chip_numpad'),
            chipFontColor: this.showNumPadVal ? DPAD_ARROW : NUMKEY_TEXT,
            onChipClick: () => { this.showNumPadVal = !this.showNumPadVal; }
          }).margin(3)
          if (this.gamepadConnected) {
            StatusBarChip({ chipLabel: '🎮', chipFontColor: RUN_DOT }).margin(3)
          }
        }
        .margin({ top: 24 })
        .constraintSize({ maxWidth: '90%' })
      }
      .width('25%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 8, right: 8 })
      .onAreaChange((_old: Area, newVal: Area) => {
        this.leftColW = newVal.width as number;
      })

      Column() {
        TopScreen({
          nodeContent: this.nodeContent,
          statusText: this.statusText,
          runningState: this.runningState,
          scaleVal: Math.min((this.midColW - 24) / this.bufW, (this.midColH - 40) / this.bufH),
          bufW: this.bufW,
          bufH: this.bufH,
          screenVisible: this.screenVisible,
          speedMultiplier: this.speedMultiplier,
          onSpeedChange: (mult: number) => {
            this.speedMultiplier = mult;
            this.engine.setSpeedMultiplier(mult);
          }
        })
      }
      .width('50%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onAreaChange((_old: Area, newVal: Area) => {
        this.midColW = newVal.width as number;
        this.midColH = newVal.height as number;
      })

      Column() {
        if (this.showNumPadVal) {
          NumPad({
            onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e),
            btnSizeVal: Math.min(this.rightColW * 0.2, 48),
            gapVal: Math.min(this.rightColW * 0.06, 16),
            widthVal: '85%'
          })
        }
      }
      .width('25%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 8, right: 8 })
      .onAreaChange((_old: Area, newVal: Area) => {
        this.rightColW = newVal.width as number;
      })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.avoidData.bottomVp })
  }

  @Builder
  tabletPortraitLayout() {
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
          .backgroundColor(this.runningState ? RUN_DOT : $r('app.color.emulator_idle_dot'))
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
        StatusBarChip({ chipLabel: $r('app.string.emulator_chip_settings'), onChipClick: () => this.navPathStack.pushPathByName('Settings', null) })
        StatusBarChip({
          chipLabel: $r('app.string.emulator_chip_numpad'),
          chipFontColor: this.showNumPadVal ? DPAD_ARROW : NUMKEY_TEXT,
          onChipClick: () => { this.showNumPadVal = !this.showNumPadVal; }
        })
        StatusBarChip({
          chipLabel: this.showControls ? $r('app.string.emulator_chip_collapse') : $r('app.string.emulator_chip_controls'),
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
            panelBgColor: $r('app.color.emulator_panel_bg'),
            panelBorderWidth: 1
          }) {
            Scroll() {
              Column() {
                Row() {
                  DPadWithFunc({
                    onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e),
                    dpadSize: Math.min(this.screenAreaW * 0.25, 160)
                  })

                  if (this.showNumPadVal) {
                    NumPad({
                      onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e),
                      btnSizeVal: Math.min(this.screenAreaW * 0.08, 44)
                    })
                  }
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
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
        .constraintSize({ maxWidth: 720 })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: this.avoidData.bottomVp })
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
          .backgroundColor(this.runningState ? RUN_DOT : $r('app.color.emulator_idle_dot'))
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
          StatusBarChip({ chipLabel: $r('app.string.emulator_chip_settings'), onChipClick: () => this.navPathStack.pushPathByName('Settings', null) })
         StatusBarChip({
           chipLabel: $r('app.string.emulator_chip_numpad'),
          chipFontColor: this.showNumPadVal ? DPAD_ARROW : NUMKEY_TEXT,
          onChipClick: () => { this.showNumPadVal = !this.showNumPadVal; }
        })
        StatusBarChip({
           chipLabel: this.showControls ? $r('app.string.emulator_chip_collapse') : $r('app.string.emulator_chip_controls'),
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
             panelBgColor: $r('app.color.emulator_panel_bg'),
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
           .shadow({ radius: 12, color: $r('app.color.immersive_shadow'), offsetX: 0, offsetY: 4 })
        }
        .width('100%')
        .height('50%')
        .alignContent(Alignment.Center)

        Row() {
          Row()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.runningState ? RUN_DOT : $r('app.color.emulator_idle_dot'))
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
          panelBgColor: $r('app.color.emulator_panel_bg'),
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
                      Text(this.showNumPadVal ? $r('app.string.emulator_btn_collapse_numpad') : $r('app.string.emulator_chip_numpad'))
                        .fontSize(11)
                        .fontColor(this.showNumPadVal ? DPAD_ARROW : $r('app.color.emulator_softkey_text'))
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



  build() {
    HdsNavDestination() {
      Column() {
        if (this.isFoldable && (this.foldStatus === display.FoldStatus.FOLD_STATUS_EXPANDED ||
          this.foldStatus === display.FoldStatus.FOLD_STATUS_HALF_FOLDED)) {
          this.foldExpandedLayout()
        } else if (this.currentBp === 'sm') {
          this.phoneLayout()
        } else if (this.isLandscape) {
          this.tabletLandscapeLayout()
        } else {
          this.tabletPortraitLayout()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.emulator_bg'))
      .focusScopeId('emulatorGroup', true, false)
      .defaultFocus(true)
      .onAreaChange((_old: Area, newVal: Area) => {
        const w = newVal.width as number;
        const h = newVal.height as number;
        this.isLandscape = w > h;
        if (w >= 840) {
          this.currentBp = 'lg';
        } else if (w >= 520) {
          this.currentBp = 'md';
        } else {
          this.currentBp = 'sm';
        }
      })
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
