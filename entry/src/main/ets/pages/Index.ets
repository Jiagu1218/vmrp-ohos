import { picker } from '@kit.CoreFileKit';
import { NodeContent, ComponentContent, AppStorageV2 } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import {
  VmrpEngineTs, VMRP_KEY_PRESS, VMRP_KEY_RELEASE,
  MR_KEY_UP, MR_KEY_DOWN, MR_KEY_LEFT, MR_KEY_RIGHT,
  MR_KEY_SELECT, MR_KEY_SOFTLEFT, MR_KEY_SOFTRIGHT,
  MR_KEY_STAR, MR_KEY_POUND
} from '../vmrp/VmrpEngine';
import { VmrpAssets } from '../vmrp/VmrpAssets';
import { gAbilityContext } from '../entryability/EntryAbility';
import { AvoidData } from '../common/AvoidData';

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

const SHELL_COLOR = '#1A1A2E';
const HINGE_COLOR = '#2D2D44';
const ACCENT_COLOR = '#E94560';
const SCREEN_BG = '#000000';
const DPAD_BG = '#16213E';
const DPAD_ARROW = '#E94560';
const SOFTKEY_BG = '#0F3460';
const NUMKEY_BG = '#1A1A2E';
const NUMKEY_TEXT = '#A7A7C4';
const STATUS_TEXT = '#8888AA';
const RUN_DOT = '#4ADE80';
const SHELL_BORDER = '#2A2A4E';

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
struct DPadWithFunc {
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};
  @Param dpadSize: number = 130;
  @Param softKeyH: number = 28;

  build() {
    Column({ space: 14 }) {
      Row() {
        Stack() {
          Text('左软')
            .fontSize(12)
            .fontColor('#CCCCCC')
            .fontWeight(FontWeight.Medium)
        }
        .height(this.softKeyH)
        .padding({ left: 16, right: 16 })
        .borderRadius(this.softKeyH / 2)
        .backgroundColor(SOFTKEY_BG)
        .onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_SOFTLEFT, e))

        Stack() {
          Text('▲')
            .fontSize(this.dpadSize * 0.2)
            .fontColor(DPAD_ARROW)
            .fontWeight(FontWeight.Bold)
        }
        .width(this.dpadSize * 0.36)
        .height(this.dpadSize * 0.36)
        .borderRadius(8)
        .backgroundColor(DPAD_BG)
        .margin({ left: 24, right: 24 })
        .onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_UP, e))

        Stack() {
          Text('右软')
            .fontSize(12)
            .fontColor('#CCCCCC')
            .fontWeight(FontWeight.Medium)
        }
        .height(this.softKeyH)
        .padding({ left: 16, right: 16 })
        .borderRadius(this.softKeyH / 2)
        .backgroundColor(SOFTKEY_BG)
        .onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_SOFTRIGHT, e))
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Row({ space: 16 }) {
        Stack() {
          Text('◀')
            .fontSize(this.dpadSize * 0.17)
            .fontColor(DPAD_ARROW)
            .fontWeight(FontWeight.Bold)
        }
        .width(this.dpadSize * 0.36)
        .height(this.dpadSize * 0.36)
        .borderRadius(8)
        .backgroundColor(DPAD_BG)
        .onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_LEFT, e))

        Stack() {
          Text('OK')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .width(this.dpadSize * 0.28)
        .height(this.dpadSize * 0.28)
        .borderRadius(this.dpadSize * 0.14)
        .backgroundColor(ACCENT_COLOR)
        .onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_SELECT, e))

        Stack() {
          Text('▶')
            .fontSize(this.dpadSize * 0.17)
            .fontColor(DPAD_ARROW)
            .fontWeight(FontWeight.Bold)
        }
        .width(this.dpadSize * 0.36)
        .height(this.dpadSize * 0.36)
        .borderRadius(8)
        .backgroundColor(DPAD_BG)
        .onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_RIGHT, e))
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Row() {
        Stack() {
          Text('▼')
            .fontSize(this.dpadSize * 0.2)
            .fontColor(DPAD_ARROW)
            .fontWeight(FontWeight.Bold)
        }
        .width(this.dpadSize * 0.36)
        .height(this.dpadSize * 0.36)
        .borderRadius(8)
        .backgroundColor(DPAD_BG)
        .onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_DOWN, e))
      }
      .justifyContent(FlexAlign.Center)
    }
    .alignItems(HorizontalAlign.Center)
  }
}

@ComponentV2
struct SoftKeys {
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};

  build() {
    Row({ space: 10 }) {
      Stack() {
        Text('左软')
          .fontSize(12)
          .fontColor('#CCCCCC')
          .fontWeight(FontWeight.Medium)
      }
      .height(26)
      .padding({ left: 16, right: 16 })
      .borderRadius(13)
      .backgroundColor(SOFTKEY_BG)
      .onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_SOFTLEFT, e))

      Stack() {
        Text('右软')
          .fontSize(12)
          .fontColor('#CCCCCC')
          .fontWeight(FontWeight.Medium)
      }
      .height(26)
      .padding({ left: 16, right: 16 })
      .borderRadius(13)
      .backgroundColor(SOFTKEY_BG)
      .onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_SOFTRIGHT, e))
    }
    .justifyContent(FlexAlign.Center)
  }
}

@ComponentV2
struct NumPad {
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};
  @Param btnSize: number = 36;

  build() {
    Grid() {
      ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, MR_KEY_STAR, 0, MR_KEY_POUND], (k: number) => {
        GridItem() {
          Stack() {
            Text(`${k === MR_KEY_STAR ? '✱' : k === MR_KEY_POUND ? '#' : k}`)
              .fontSize(this.btnSize * 0.4)
              .fontColor(NUMKEY_TEXT)
              .fontWeight(FontWeight.Medium)
          }
          .width(this.btnSize)
          .height(this.btnSize)
          .borderRadius(this.btnSize / 2)
          .backgroundColor(NUMKEY_BG)
          .border({ width: 1, color: SHELL_BORDER })
          .onTouch((e: TouchEvent) => this.onKeyTouch(k, e))
        }
      }, (k: number) => `num-${k}`)
    }
    .columnsTemplate('1fr 1fr 1fr')
    .rowsTemplate('1fr 1fr 1fr 1fr')
    .columnsGap(10)
    .rowsGap(10)
    .width('45%')
    .height(this.btnSize * 4 + 50)
  }
}

@ComponentV2
struct TopScreen {
  @Param nodeContent: NodeContent = new NodeContent();
  @Param status: string = '';
  @Param running: boolean = false;
  @Param scaleVal: number = 1;

  build() {
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
        .scale({ x: this.scaleVal, y: this.scaleVal })
        .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
      }
      .width(240 * this.scaleVal)
      .height(320 * this.scaleVal)
      .alignContent(Alignment.Center)
      .clip(true)

      Row() {
        Row()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.running ? RUN_DOT : '#555577')
          .margin({ right: 6 })
        Text(this.status)
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
struct BottomControls {
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};
  @Param onPickMrp: () => void = () => {};
  @Param onStartDefault: () => void = () => {};
  @Param running: boolean = false;
  @Param dpadSize: number = 110;
  @Param btnSize: number = 30;

  build() {
    Column() {
      DPadWithFunc({ onKeyTouch: this.onKeyTouch, dpadSize: this.dpadSize })

      NumPad({ onKeyTouch: this.onKeyTouch, btnSize: this.btnSize })

      Row({ space: 8 }) {
        Stack() {
          Text('选择MRP')
            .fontSize(11)
            .fontColor('#CCCCCC')
        }
        .height(26)
        .padding({ left: 14, right: 14 })
        .borderRadius(13)
        .backgroundColor(SOFTKEY_BG)
        .onClick(() => this.onPickMrp())

        Stack() {
          Text('启动默认')
            .fontSize(11)
            .fontColor('#CCCCCC')
        }
        .height(26)
        .padding({ left: 14, right: 14 })
        .borderRadius(13)
        .backgroundColor(SOFTKEY_BG)
        .onClick(() => this.onStartDefault())
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
  @Param running: boolean = false;

  build() {
    Column({ space: 6 }) {
      Row() {
        DPadWithFunc({ onKeyTouch: this.onKeyTouch, dpadSize: 110 })
          .layoutWeight(1)

        NumPad({ onKeyTouch: this.onKeyTouch, btnSize: 30 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
  }
}

@Entry
@ComponentV2
struct Index {
  @Local status: string = '未启动';
  @Local running: boolean = false;
  @Local editText: string = '';
  @Local currentBp: string = 'sm';
  @Local showControls: boolean = true;
  @Local isFoldable: boolean = false;
  @Local foldStatus: display.FoldStatus = display.FoldStatus.FOLD_STATUS_UNKNOWN;
  @Local screenAreaW: number = 240;
  @Local screenAreaH: number = 320;
  @Local dualAreaW: number = 400;
  @Local dualAreaH: number = 600;
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
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
      this.status = '正在加载...';
      await this.engine.init();
      const ctx = gAbilityContext ?? this.getUIContext().getHostContext();
      if (!ctx) {
        this.status = '初始化失败';
        return;
      }
      this.status = '准备资源...';
      const workDir = await VmrpAssets.ensureRuntime(ctx);
      let ok = this.engine.loadLib('libvmrp.so');
      if (!ok) {
        ok = this.engine.loadLib(`${ctx.bundleCodeDir}/lib/arm64/libvmrp.so`);
      }
      if (!ok) {
        this.status = '加载失败';
        return;
      }
      this.engine.setScreen(240, 320);
      this.engine.setWorkDir(workDir);
      this.engine.setEditCallback((editText: string) => {
        this.editText = editText;
        this.openEditDialog();
      });
      this.engine.createSurfaceNode(this.nodeContent);
      this.status = '启动中...';
      await this.startDefault();
    } catch (e) {
      const err = e as Error;
      this.status = `失败: ${err?.message ?? String(e)}`;
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
        this.status = '无法获取上下文';
        return;
      }
      const workDir = await VmrpAssets.ensureRuntime(ctx);
      const dst = `${VmrpAssets.getMythroadDir(ctx)}/dsm_gm.mrp`;
      this.status = '启动中';
      const r = this.engine.start(dst, 'start.mr', '_dsm');
      this.running = this.engine.isRunning();
      this.status = `${r}, ${this.running ? '运行中' : '已停止'}`;
    } catch (e) {
      const err = e as Error;
      this.status = `失败: ${err?.message ?? String(e)}`;
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
        this.status = '无法获取上下文';
        return;
      }
      const dst = await VmrpAssets.importMrp(ctx, uris[0]);
      this.status = `启动: ${dst}`;
      const r = this.engine.start(dst, 'start.mr', '_dsm');
      this.running = this.engine.isRunning();
      this.status = `${r}, ${this.running ? '运行中' : '已停止'}`;
    } catch (e) {
      this.status = `选择失败: ${JSON.stringify(e)}`;
    }
  }

  onKeyTouch(key: number, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (!this.pressedKeys.has(key)) {
        this.pressedKeys.add(key);
        this.engine.sendKey(VMRP_KEY_PRESS, key);
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
          status: this.status,
          running: this.running,
          scaleVal: this.currentBp === 'sm' ? 1 : Math.min((this.dualAreaW - 24) / 240, (this.dualAreaH * 0.5 - 36) / 320)
        })
      } else {
        Scroll() {
          Column() {
            BottomControls({
              onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e),
              onPickMrp: () => this.pickAndStart(),
              onStartDefault: () => this.startDefault(),
              running: this.running,
              dpadSize: this.currentBp === 'sm' ? 110 : Math.min((this.dualAreaW - 24) * 0.4, 130),
              btnSize: this.currentBp === 'sm' ? 30 : Math.min((this.dualAreaW - 24) * 0.1, 36)
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
    .backgroundColor(SHELL_COLOR)
    .borderRadius(16)
    .padding(12)
    .border({ width: 1, color: SHELL_BORDER })
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
          .backgroundColor(this.running ? RUN_DOT : '#555577')
          .margin({ right: 6 })
        Text(this.status)
          .fontSize(10)
          .fontColor(STATUS_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Stack() {
          Text('MRP')
            .fontSize(9)
            .fontColor(NUMKEY_TEXT)
        }
        .height(18)
        .padding({ left: 6, right: 6 })
        .borderRadius(9)
        .backgroundColor(NUMKEY_BG)
        .margin({ right: 4 })
        .onClick(() => this.pickAndStart())
        Stack() {
          Text('默认')
            .fontSize(9)
            .fontColor(NUMKEY_TEXT)
        }
        .height(18)
        .padding({ left: 6, right: 6 })
        .borderRadius(9)
        .backgroundColor(NUMKEY_BG)
        .margin({ right: 4 })
        .onClick(() => this.startDefault())
        Stack() {
          Text(this.showControls ? '收起' : '按键')
            .fontSize(9)
            .fontColor(DPAD_ARROW)
        }
        .height(18)
        .padding({ left: 8, right: 8 })
        .borderRadius(9)
        .backgroundColor(DPAD_BG)
        .onClick(() => { this.showControls = !this.showControls; })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })

      if (this.showControls) {
        Scroll() {
          Column() {
            PhoneControls({
              onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e),
              running: this.running
            })
          }
          .width('100%')
          .backgroundColor(SHELL_COLOR)
          .borderRadius({ topLeft: 16, topRight: 16 })
          .border({ width: 1, color: SHELL_BORDER })
          .padding({ top: 4, bottom: 4 })
        }
        .constraintSize({ maxHeight: '46%' })
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
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
            .backgroundColor(this.running ? RUN_DOT : '#555577')
            .margin({ right: 6 })
          Text(this.status)
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

      Scroll() {
        Column() {
          Row() {
            DPadWithFunc({ onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e), dpadSize: Math.min(this.screenAreaW * 0.22, 120) })
              .layoutWeight(1)

            NumPad({ onKeyTouch: (key: number, e: TouchEvent) => this.onKeyTouch(key, e), btnSize: Math.min(this.screenAreaW * 0.07, 34) })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: 8 }) {
            Stack() {
              Text('选择MRP')
                .fontSize(11)
                .fontColor('#CCCCCC')
            }
            .height(26)
            .padding({ left: 14, right: 14 })
            .borderRadius(13)
            .backgroundColor(SOFTKEY_BG)
            .onClick(() => this.pickAndStart())

            Stack() {
              Text('启动默认')
                .fontSize(11)
                .fontColor('#CCCCCC')
            }
            .height(26)
            .padding({ left: 14, right: 14 })
            .borderRadius(13)
            .backgroundColor(SOFTKEY_BG)
            .onClick(() => this.startDefault())
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
      .backgroundColor(SHELL_COLOR)
      .borderRadius({ topLeft: 16, topRight: 16 })
      .border({ width: 1, color: SHELL_BORDER })
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
          this.screenShell({ isTop: true })
        }
        .width('100%')
        .height('100%')
      }
      .height('100%')

      GridCol({ span: this.bottomSpan }) {
        Column() {
          this.screenShell({ isTop: false })
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
    .padding({ top: this.avoidData.topVp, bottom: this.avoidData.bottomVp })
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
