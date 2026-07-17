import { picker } from '@kit.CoreFileKit';
import { abilityAccessCtrl } from '@kit.AbilityKit';
import { NodeContent, ComponentContent, AppStorageV2, display } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import {
  HdsNavigation, HdsNavigationTitleMode,
  ScrollEffectType, hdsMaterial
} from '@kit.UIDesignKit';
import {
  VmrpEngineTs, VMRP_KEY_PRESS, VMRP_KEY_RELEASE,
  MR_KEY_UP, MR_KEY_DOWN, MR_KEY_LEFT, MR_KEY_RIGHT,
  MR_KEY_SELECT, MR_KEY_SOFTLEFT, MR_KEY_SOFTRIGHT,
  MR_KEY_STAR, MR_KEY_POUND
} from '../vmrp/VmrpEngine';
import { VmrpAssets } from '../vmrp/VmrpAssets';
import { gAbilityContext } from '../entryability/EntryAbility';
import { AvoidData } from '../common/AvoidData';
import { HapticManager } from '../common/HapticManager';
import { ImmersiveLightWrapper } from '../common/ImmersiveLightWrapper';
import { GlassPanel } from '../common/GlassPanel';

interface ScreenShellParam {
  isTop: boolean;
}

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

interface EditDialogContentBuilderParams {
  editText: string;
  onTextChange: (v: string) => void;
  onSubmit: (text: string) => void;
  onCancel: () => void;
}

interface EditDialogOptions {
  alignment: DialogAlignment;
  autoCancel: boolean;
}

const SHELL_COLOR = '#1A1A2E';
const SCREEN_BG = '#000000';
const DPAD_BG = '#16213E';
const DPAD_ARROW = '#E94560';
const SOFTKEY_BG = '#0F3460';
const NUMKEY_BG = '#1A1A2E';
const NUMKEY_TEXT = '#A7A7C4';
const STATUS_TEXT = '#8888AA';
const RUN_DOT = '#4ADE80';
const SHELL_BORDER = '#2A2A4E';
const ACCENT_COLOR = '#E94560';

@ComponentV2
struct EditDialogContent {
  @Param editText: string = '';
  @Event onTextChange: (v: string) => void = () => {};
  @Event onSubmit: (text: string) => void = () => {};
  @Event onCancel: () => void = () => {};
  @Local private inputText: string = '';

  aboutToAppear(): void {
    this.inputText = this.editText;
  }

  build() {
    Column() {
      Text('请输入文字')
        .fontSize(16)
        .fontColor('#CCCCCC')
        .margin({ top: 16, bottom: 10 })
      TextArea({ text: this.inputText })
        .onChange((v: string) => { this.inputText = v; })
        .width('90%')
        .layoutWeight(1)
        .fontSize(16)
        .backgroundColor('#1A1A2E')
        .fontColor('#FFFFFF')
      Row() {
        Button('取消')
          .width(100)
          .height(40)
          .backgroundColor('#333355')
          .fontColor('#CCCCCC')
          .onClick(() => {
            this.onCancel();
          })
        Button('确定')
          .width(100)
          .height(40)
          .backgroundColor(ACCENT_COLOR)
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.onSubmit(this.inputText);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .margin({ top: 12, bottom: 16 })
    }
    .width('82%')
    .height(340)
    .backgroundColor(SHELL_COLOR)
    .borderRadius(16)
  }
}

@ComponentV2
struct DPadBtn {
  @Param label: string = '';
  @Param labelFontSize: number = 14;
  @Param labelFontColor: ResourceColor = DPAD_ARROW;
  @Param btnSize: number = 44;
  @Param isRound: boolean = false;
  @Param keyVal: number = 0;
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};

  build() {
    Column() {
      ImmersiveLightWrapper({ radius: this.isRound ? this.btnSize / 2 : 8, lightHeight: 80 }) {
        Stack() {
          Text(this.label)
            .fontSize(this.labelFontSize)
            .fontColor(this.labelFontColor)
            .fontWeight(FontWeight.Bold)
        }
        .width(this.btnSize)
        .height(this.btnSize)
        .borderRadius(this.isRound ? this.btnSize / 2 : 8)
        .backgroundColor(Color.Transparent)
      }
    }
    .onTouch((e: TouchEvent) => this.onKeyTouch(this.keyVal, e))
  }
}

@ComponentV2
struct SoftKeyBtn {
  @Param chipLabel: string = '';
  @Param keyVal: number = 0;
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};
  @Param softKeyH: number = 28;

  build() {
    Column() {
      ImmersiveLightWrapper({ radius: this.softKeyH / 2, lightHeight: 80 }) {
        Stack() {
          Text(this.chipLabel)
            .fontSize(12)
            .fontColor('#CCCCCC')
            .fontWeight(FontWeight.Medium)
        }
        .height(this.softKeyH)
        .padding({ left: 16, right: 16 })
        .backgroundColor(Color.Transparent)
      }
    }
    .onTouch((e: TouchEvent) => this.onKeyTouch(this.keyVal, e))
  }
}

@ComponentV2
struct DPadWithFunc {
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};
  @Param dpadSize: number = 130;
  @Param softKeyH: number = 28;

  build() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        SoftKeyBtn({ chipLabel: '左软', keyVal: MR_KEY_SOFTLEFT, onKeyTouch: this.onKeyTouch, softKeyH: this.softKeyH })

        DPadBtn({
          label: '▲', labelFontSize: this.dpadSize * 0.2, labelFontColor: DPAD_ARROW,
          btnSize: this.dpadSize * 0.36, keyVal: MR_KEY_UP,
          onKeyTouch: this.onKeyTouch
        })

        SoftKeyBtn({ chipLabel: '右软', keyVal: MR_KEY_SOFTRIGHT, onKeyTouch: this.onKeyTouch, softKeyH: this.softKeyH })
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Row({ space: 16 }) {
        DPadBtn({
          label: '◀', labelFontSize: this.dpadSize * 0.17, labelFontColor: DPAD_ARROW,
          btnSize: this.dpadSize * 0.36, keyVal: MR_KEY_LEFT,
          onKeyTouch: this.onKeyTouch
        })

        DPadBtn({
          label: 'OK', labelFontSize: 14, labelFontColor: '#FFFFFF',
          btnSize: this.dpadSize * 0.28,
          isRound: true, keyVal: MR_KEY_SELECT, onKeyTouch: this.onKeyTouch
        })

        DPadBtn({
          label: '▶', labelFontSize: this.dpadSize * 0.17, labelFontColor: DPAD_ARROW,
          btnSize: this.dpadSize * 0.36, keyVal: MR_KEY_RIGHT,
          onKeyTouch: this.onKeyTouch
        })
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Row() {
        DPadBtn({
          label: '▼', labelFontSize: this.dpadSize * 0.2, labelFontColor: DPAD_ARROW,
          btnSize: this.dpadSize * 0.36, keyVal: MR_KEY_DOWN,
          onKeyTouch: this.onKeyTouch
        })
      }
      .justifyContent(FlexAlign.Center)
    }
    .alignItems(HorizontalAlign.Center)
  }
}

@ComponentV2
struct NumPadItem {
  @Param itemKey: number = 0;
  @Param btnSizeVal: number = 36;
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};

  build() {
    Column() {
      ImmersiveLightWrapper({ radius: this.btnSizeVal / 2, lightHeight: 60 }) {
        Stack() {
          Text(`${this.itemKey === MR_KEY_STAR ? '✱' : this.itemKey === MR_KEY_POUND ? '#' : this.itemKey}`)
            .fontSize(this.btnSizeVal * 0.4)
            .fontColor(NUMKEY_TEXT)
            .fontWeight(FontWeight.Medium)
        }
        .width(this.btnSizeVal)
        .height(this.btnSizeVal)
        .backgroundColor(Color.Transparent)
      }
    }
    .onTouch((e: TouchEvent) => this.onKeyTouch(this.itemKey, e))
  }
}

@ComponentV2
struct NumPad {
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};
  @Param btnSizeVal: number = 36;

  build() {
    Grid() {
      ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, MR_KEY_STAR, 0, MR_KEY_POUND], (k: number) => {
        GridItem() {
          NumPadItem({ itemKey: k, btnSizeVal: this.btnSizeVal, onKeyTouch: this.onKeyTouch })
        }
      }, (k: number) => `num-${k}`)
    }
    .columnsTemplate('1fr 1fr 1fr')
    .rowsTemplate('1fr 1fr 1fr 1fr')
    .columnsGap(10)
    .rowsGap(10)
    .width('45%')
    .height(this.btnSizeVal * 4 + 50)
  }
}

@ComponentV2
struct TopScreen {
  @Param nodeContent: NodeContent = new NodeContent();
  @Param statusText: string = '';
  @Param runningState: boolean = false;
  @Param scaleVal: number = 1;

  build() {
    Column() {
      Stack() {
        Stack() {
          Stack() {
            ContentSlot(this.nodeContent)
          }
          .width(240)
          .height(320)
          .backgroundColor(SCREEN_BG)
          .borderRadius(6)
          .clip(true)
          .scale({ x: this.scaleVal, y: this.scaleVal })
          .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
        }
        .width(240 * this.scaleVal)
        .height(320 * this.scaleVal)
        .alignContent(Alignment.Center)
        .clip(true)
      }
      .width('100%')

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
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 2 })
      .constraintSize({ maxWidth: 240 * this.scaleVal + 16 })
    }
    .alignItems(HorizontalAlign.Center)
  }
}

@ComponentV2
struct ActionChip {
  @Param chipLabel: string = '';
  @Param onChipClick: () => void = () => {};

  build() {
    Column() {
      ImmersiveLightWrapper({ radius: 13, lightHeight: 80 }) {
        Stack() {
          Text(this.chipLabel)
            .fontSize(11)
            .fontColor('#CCCCCC')
        }
        .height(26)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Color.Transparent)
      }
    }
    .onClick(() => { HapticManager.performClick(); this.onChipClick(); })
  }
}

@ComponentV2
struct StatusBarChip {
  @Param chipLabel: string = '';
  @Param chipFontColor: ResourceColor = NUMKEY_TEXT;
  @Param chipBgColor: ResourceColor = NUMKEY_BG;
  @Param onChipClick: () => void = () => {};

  build() {
    Column() {
      ImmersiveLightWrapper({ radius: 9, lightHeight: 60 }) {
        Stack() {
          Text(this.chipLabel)
            .fontSize(9)
            .fontColor(this.chipFontColor)
        }
        .height(18)
        .padding({ left: 6, right: 6 })
        .backgroundColor(Color.Transparent)
      }
    }
    .margin({ right: 4 })
    .onClick(() => { HapticManager.performClick(); this.onChipClick(); })
  }
}

@ComponentV2
struct BottomControls {
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};
  @Param onPickMrp: () => void = () => {};
  @Param onStartDefault: () => void = () => {};
  @Param runningState: boolean = false;
  @Param dpadSizeVal: number = 110;
  @Param btnSizeVal: number = 30;
  @Param showNumPadVal: boolean = true;

  build() {
    Column() {
      DPadWithFunc({ onKeyTouch: this.onKeyTouch, dpadSize: this.dpadSizeVal })

      if (this.showNumPadVal) {
        NumPad({ onKeyTouch: this.onKeyTouch, btnSizeVal: this.btnSizeVal })
      }

      Row({ space: 8 }) {
        ActionChip({ chipLabel: '选择MRP', onChipClick: this.onPickMrp })
        ActionChip({ chipLabel: '启动默认', onChipClick: this.onStartDefault })
      }
      .padding({ top: 4, bottom: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 8, right: 8, top: 4, bottom: 8 })
  }
}

@ComponentV2
struct PhoneControls {
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};
  @Param runningState: boolean = false;
  @Param showNumPadVal: boolean = true;

  build() {
    Column({ space: 6 }) {
      Row() {
        DPadWithFunc({ onKeyTouch: this.onKeyTouch, dpadSize: 110 })

        if (this.showNumPadVal) {
          NumPad({ onKeyTouch: this.onKeyTouch, btnSizeVal: 30 })
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
  }
}

@Entry
@ComponentV2
struct Index {
  @Local statusText: string = '未启动';
  @Local runningState: boolean = false;
  @Local editText: string = '';
  @Local currentBp: string = 'sm';
  @Local showControls: boolean = true;
  @Local showNumPadVal: boolean = true;
  @Local isFoldable: boolean = false;
  @Local foldStatus: display.FoldStatus = display.FoldStatus.FOLD_STATUS_UNKNOWN;
  @Local screenAreaW: number = 240;
  @Local screenAreaH: number = 320;
  @Local dualAreaW: number = 400;
  @Local dualAreaH: number = 600;
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
  private navPathStack: NavPathStack = new NavPathStack();
  private engine: VmrpEngineTs = new VmrpEngineTs();
  private pressedKeys: Set<number> = new Set();
  private nodeContent: NodeContent = new NodeContent();
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
        this.engine.setDisplayFilter(displayFilter, screenEffect, screenEffectStrength,
          brightness, contrast, saturation);
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
      this.engine.createSurfaceNode(this.nodeContent);
      this.statusText = '启动中...';
      await this.startDefault();
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

  async startDefault(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        this.statusText = '无法获取上下文';
        return;
      }
      const workDir = await VmrpAssets.ensureRuntime(ctx);
      const dst = `${VmrpAssets.getMythroadDir(ctx)}/dsm_gm.mrp`;
      this.statusText = '启动中';
      const r = this.engine.start(dst, 'start.mr', '_dsm');
      this.runningState = this.engine.isRunning();
      this.statusText = `${r}, ${this.runningState ? '运行中' : '已停止'}`;
    } catch (e) {
      const err = e as Error;
      this.statusText = `失败: ${err?.message ?? String(e)}`;
    }
  }

  async pickAndStart(): Promise<void> {
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['.mrp'];
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.select(opt);
      if (!uris || uris.length === 0) return;
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        this.statusText = '无法获取上下文';
        return;
      }
      const dst = await VmrpAssets.importMrp(ctx, uris[0]);
      this.statusText = `启动: ${dst}`;
      const r = this.engine.start(dst, 'start.mr', '_dsm');
      this.runningState = this.engine.isRunning();
      this.statusText = `${r}, ${this.runningState ? '运行中' : '已停止'}`;
    } catch (e) {
      this.statusText = `选择失败: ${JSON.stringify(e)}`;
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

  @Builder
  screenShell($$: ScreenShellParam) {
    Column() {
      if ($$.isTop) {
        TopScreen({
          nodeContent: this.nodeContent,
          statusText: this.statusText,
          runningState: this.runningState,
          scaleVal: this.currentBp === 'sm' ? 1 : Math.min((this.dualAreaW - 24) / 240, (this.dualAreaH * 0.5 - 36) / 320)
        })
      } else {
        Scroll() {
          Column() {
            BottomControls({
              onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e),
              onPickMrp: () => this.pickAndStart(),
              onStartDefault: () => this.startDefault(),
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
          ContentSlot(this.nodeContent)
        }
        .width(240)
        .height(320)
        .backgroundColor(SCREEN_BG)
        .scale({
          x: Math.min(this.screenAreaW / 240, this.screenAreaH / 320),
          y: Math.min(this.screenAreaW / 240, this.screenAreaH / 320)
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
        StatusBarChip({ chipLabel: 'MRP', onChipClick: () => this.pickAndStart() })
        StatusBarChip({ chipLabel: '默认', onChipClick: () => this.startDefault() })
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
            ContentSlot(this.nodeContent)
          }
          .width(240)
          .height(320)
          .backgroundColor(SCREEN_BG)
          .borderRadius(6)
          .clip(true)
          .scale({
            x: Math.min(this.screenAreaW / 240, this.screenAreaH * 0.48 / 320),
            y: Math.min(this.screenAreaW / 240, this.screenAreaH * 0.48 / 320)
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
                ActionChip({ chipLabel: '选择MRP', onChipClick: () => this.pickAndStart() })
                ActionChip({ chipLabel: '启动默认', onChipClick: () => this.startDefault() })
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
    HdsNavigation(this.navPathStack) {
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
    }
    .width('100%')
    .height('100%')
    .hideTitleBar(true)
    .titleMode(HdsNavigationTitleMode.MINI)
    .mode(NavigationMode.Stack)
  }
}

@Builder
function EditDialogContentBuilder($$: EditDialogContentBuilderParams) {
  EditDialogContent({
    editText: $$.editText,
    onTextChange: $$.onTextChange,
    onSubmit: $$.onSubmit,
    onCancel: $$.onCancel
  })
}
