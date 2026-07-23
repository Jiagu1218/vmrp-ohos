import { NodeContent } from '@kit.ArkUI';
import {
  MR_KEY_UP, MR_KEY_DOWN, MR_KEY_LEFT, MR_KEY_RIGHT,
  MR_KEY_SELECT, MR_KEY_SOFTLEFT, MR_KEY_SOFTRIGHT,
  MR_KEY_STAR, MR_KEY_POUND
} from '../vmrp/VmrpEngine';
import { HapticManager } from '../common/HapticManager';
import { ImmersiveLightWrapper } from '../common/ImmersiveLightWrapper';
import { GlassPanel } from '../common/GlassPanel';

export interface ScreenShellParam {
  isTop: boolean;
}

export interface EditDialogContentBuilderParams {
  editText: string;
  onTextChange: (v: string) => void;
  onSubmit: (text: string) => void;
  onCancel: () => void;
}

export interface EditDialogOptions {
  alignment: DialogAlignment;
  autoCancel: boolean;
}

export const SHELL_COLOR = '#1A1A2E';
export const SCREEN_BG = '#000000';
export const DPAD_BG = '#16213E';
export const DPAD_ARROW = '#E94560';
export const SOFTKEY_BG = '#0F3460';
export const NUMKEY_BG = '#1A1A2E';
export const NUMKEY_TEXT = '#A7A7C4';
export const STATUS_TEXT = '#8888AA';
export const RUN_DOT = '#4ADE80';
export const SHELL_BORDER = '#2A2A4E';
export const ACCENT_COLOR = '#E94560';

@ComponentV2
export struct DPadBtn {
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
export struct SoftKeyBtn {
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
export struct DPadWithFunc {
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
export struct NumPadItem {
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
export struct NumPad {
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
export struct TopScreen {
  @Param nodeContent: NodeContent = new NodeContent();
  @Param statusText: string = '';
  @Param runningState: boolean = false;
  @Param scaleVal: number = 1;
  @Param bufW: number = 240;
  @Param bufH: number = 320;
  @Param screenVisible: boolean = true;
  @Param speedMultiplier: number = 1;
  @Param onSpeedChange: (mult: number) => void = () => {};

  build() {
    Column() {
      Stack() {
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
           .scale({ x: this.scaleVal, y: this.scaleVal })
           .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
        }
        .width(this.bufW * this.scaleVal)
        .height(this.bufH * this.scaleVal)
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
         StatusBarChip({
           chipLabel: `${this.speedMultiplier}x`,
           chipFontColor: this.speedMultiplier > 1 ? $r('app.color.accent_color') : DPAD_ARROW,
           onChipClick: () => {
             const next = this.speedMultiplier >= 4 ? 1 : this.speedMultiplier + 1;
             this.onSpeedChange(next);
           }
         })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 2 })
      .constraintSize({ maxWidth: 240 * this.scaleVal + 16 })
    }
    .alignItems(HorizontalAlign.Center)
  }
}

@ComponentV2
export struct StatusBarChip {
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
export struct BottomControls {
  @Param onKeyTouch: (key: number, event: TouchEvent) => void = () => {};
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
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 8, right: 8, top: 4, bottom: 8 })
  }
}

@ComponentV2
export struct PhoneControls {
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

@ComponentV2
export struct EditDialogContent {
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

@Builder
export function EditDialogContentBuilder($$: EditDialogContentBuilderParams) {
  EditDialogContent({
    editText: $$.editText,
    onTextChange: $$.onTextChange,
    onSubmit: $$.onSubmit,
    onCancel: $$.onCancel
  })
}
