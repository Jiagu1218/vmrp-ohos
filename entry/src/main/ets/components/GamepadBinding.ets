import { KeyCode } from '@kit.InputKit';
import { ComponentContent } from '@kit.ArkUI';

export interface GpBinding {
  src: string;
  mrKeys: number[];
}

export function defaultBindings(): GpBinding[] {
  const list: GpBinding[] = [
    { src: 'dpad_up', mrKeys: [12] },
    { src: 'dpad_down', mrKeys: [13] },
    { src: 'dpad_left', mrKeys: [14] },
    { src: 'dpad_right', mrKeys: [15] },
    { src: 'dpad_up_right', mrKeys: [15, 12] },
    { src: 'dpad_down_right', mrKeys: [15, 13] },
    { src: 'dpad_down_left', mrKeys: [14, 13] },
    { src: 'dpad_up_left', mrKeys: [14, 12] },
    { src: 'stick_l_up', mrKeys: [12] },
    { src: 'stick_l_down', mrKeys: [13] },
    { src: 'stick_l_left', mrKeys: [14] },
    { src: 'stick_l_right', mrKeys: [15] },
    { src: 'stick_l_up_right', mrKeys: [15, 12] },
    { src: 'stick_l_down_right', mrKeys: [15, 13] },
    { src: 'stick_l_down_left', mrKeys: [14, 13] },
    { src: 'stick_l_up_left', mrKeys: [14, 12] },
    { src: 'stick_r_up', mrKeys: [12] },
    { src: 'stick_r_down', mrKeys: [13] },
    { src: 'stick_r_left', mrKeys: [14] },
    { src: 'stick_r_right', mrKeys: [15] },
    { src: 'stick_r_up_right', mrKeys: [15, 12] },
    { src: 'stick_r_down_right', mrKeys: [15, 13] },
    { src: 'stick_r_down_left', mrKeys: [14, 13] },
    { src: 'stick_r_up_left', mrKeys: [14, 12] },
    { src: 'btn_a', mrKeys: [20] },
    { src: 'btn_b', mrKeys: [18] },
    { src: 'btn_x', mrKeys: [17] },
    { src: 'btn_y', mrKeys: [10] },
    { src: 'btn_l1', mrKeys: [19] },
    { src: 'btn_r1', mrKeys: [11] },
    { src: 'btn_start', mrKeys: [16] },
    { src: 'btn_select', mrKeys: [17] }
  ];
  return list;
}

export function directionFirstBindings(): GpBinding[] {
  const list: GpBinding[] = defaultBindings().slice();
  list[24] = { src: 'btn_a', mrKeys: [20] };
  list[25] = { src: 'btn_b', mrKeys: [16] };
  list[26] = { src: 'btn_x', mrKeys: [17] };
  list[27] = { src: 'btn_y', mrKeys: [18] };
  list[28] = { src: 'btn_l1', mrKeys: [10] };
  list[29] = { src: 'btn_r1', mrKeys: [11] };
  list[30] = { src: 'btn_start', mrKeys: [18] };
  list[31] = { src: 'btn_select', mrKeys: [17] };
  return list;
}

export function numpadBindings(): GpBinding[] {
  const list: GpBinding[] = defaultBindings().slice();
  list[24] = { src: 'btn_a', mrKeys: [1] };
  list[25] = { src: 'btn_b', mrKeys: [2] };
  list[26] = { src: 'btn_x', mrKeys: [3] };
  list[27] = { src: 'btn_y', mrKeys: [4] };
  list[28] = { src: 'btn_l1', mrKeys: [5] };
  list[29] = { src: 'btn_r1', mrKeys: [6] };
  list[30] = { src: 'btn_start', mrKeys: [20] };
  list[31] = { src: 'btn_select', mrKeys: [10] };
  return list;
}

export function bindingsToJson(bindings: GpBinding[]): string {
  const arr: Record<string, Object>[] = [];
  for (const b of bindings) {
    const keys: number[] = b.mrKeys.slice();
    const obj: Record<string, Object> = { 'src': b.src, 'mrKeys': keys };
    arr.push(obj);
  }
  return JSON.stringify(arr);
}

export function jsonToBindings(json: string): GpBinding[] {
  const arr = JSON.parse(json) as Record<string, Object>[];
  const list: GpBinding[] = [];
  for (const obj of arr) {
    const src = obj['src'] as string;
    const mrKeys = obj['mrKeys'] as number[];
    list.push({ src: src, mrKeys: mrKeys });
  }
  return list;
}

export const GP_SRC_LABELS: Record<string, string> = {
  'dpad_up': 'D-Pad ↑', 'dpad_down': 'D-Pad ↓', 'dpad_left': 'D-Pad ←', 'dpad_right': 'D-Pad →',
  'dpad_up_right': 'D-Pad ↗', 'dpad_down_right': 'D-Pad ↘', 'dpad_down_left': 'D-Pad ↙', 'dpad_up_left': 'D-Pad ↖',
  'stick_l_up': '左摇杆 ↑', 'stick_l_down': '左摇杆 ↓', 'stick_l_left': '左摇杆 ←', 'stick_l_right': '左摇杆 →',
  'stick_l_up_right': '左摇杆 ↗', 'stick_l_down_right': '左摇杆 ↘', 'stick_l_down_left': '左摇杆 ↙', 'stick_l_up_left': '左摇杆 ↖',
  'stick_r_up': '右摇杆 ↑', 'stick_r_down': '右摇杆 ↓', 'stick_r_left': '右摇杆 ←', 'stick_r_right': '右摇杆 →',
  'stick_r_up_right': '右摇杆 ↗', 'stick_r_down_right': '右摇杆 ↘', 'stick_r_down_left': '右摇杆 ↙', 'stick_r_up_left': '右摇杆 ↖',
  'btn_a': 'A', 'btn_b': 'B', 'btn_x': 'X', 'btn_y': 'Y',
  'btn_l1': 'L1', 'btn_r1': 'R1', 'btn_start': 'Start', 'btn_select': 'Select'
};

export const MR_KEY_NAMES_MAP: Record<number, string> = {
  12: '方向上', 13: '方向下', 14: '方向左', 15: '方向右',
  20: '确认', 17: '左软键', 18: '右软键',
  10: '✱', 11: '#', 16: '电源', 19: '拨号',
  0: '0', 1: '1', 2: '2', 3: '3', 4: '4', 5: '5', 6: '6', 7: '7', 8: '8', 9: '9'
};

export function bindingDisplayText(b: GpBinding): string {
  if (b.mrKeys.length === 0) return '未设置';
  const parts: string[] = [];
  for (const k of b.mrKeys) {
    const name = MR_KEY_NAMES_MAP[k];
    parts.push(name !== undefined ? name : `${k}`);
  }
  return parts.join(' + ');
}

export const GAMEPAD_PRESET_OPTIONS: SelectOption[] = [
  { value: '经典' }, { value: '方向优先' }, { value: '数字键盘' }
];

export interface GamepadDialogParams {
  initialBindings: GpBinding[];
  onConfirm: (bindings: GpBinding[]) => void;
  onClose: () => void;
}

@ComponentV2
export struct GamepadDialogContent {
  @Param initialBindings: GpBinding[] = [];
  @Event onConfirm: (bindings: GpBinding[]) => void = (_b: GpBinding[]) => {};
  @Event onClose: () => void = () => {};
  @Local bindings: GpBinding[] = [];
  @Local listeningIdx: number = -1;
  @Local listenSrcLabel: string = '';
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const copy: GpBinding[] = [];
    for (const b of this.initialBindings) {
      const mrKeys = b.mrKeys.slice();
      copy.push({ src: b.src, mrKeys: mrKeys });
    }
    this.bindings = copy;
  }

  private handleKeyResult(src: string): void {
    if (this.listeningIdx < 0) return;
    this.bindings[this.listeningIdx].src = src;
    this.listeningIdx = -1;
    this.listenSrcLabel = '';
  }

  build() {
    Column() {
      Text('手柄按键映射')
        .fontSize(17)
        .fontColor($r('app.color.settings_about_title'))
        .fontWeight(FontWeight.Medium)
        .margin({ top: 16, bottom: 8 })

      if (this.listeningIdx >= 0) {
        Row() {
          LoadingProgress().width(16).height(16).color($r('app.color.accent_color'))
          Text(`等待按下 → ${this.listenSrcLabel}`)
            .fontSize(14)
            .fontColor($r('app.color.accent_color'))
            .fontWeight(FontWeight.Medium)
            .margin({ left: 8 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 6, bottom: 6 })
      }

      Row() {
        Text('预设:')
          .fontSize(13)
          .fontColor($r('app.color.settings_desc_color'))
        ForEach(GAMEPAD_PRESET_OPTIONS, (opt: SelectOption, idx: number) => {
          Button(opt.value as string)
            .height(28)
            .fontSize(12)
            .fontColor('#FFFFFF')
            .backgroundColor($r('app.color.settings_slider_value_bg'))
            .borderRadius(6)
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              if (idx === 0) this.bindings = defaultBindings();
              else if (idx === 1) this.bindings = directionFirstBindings();
              else if (idx === 2) this.bindings = numpadBindings();
              this.listeningIdx = -1;
              this.listenSrcLabel = '';
            })
        }, (_opt: SelectOption, idx: number) => `${idx}`)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 4, bottom: 8 })

      Scroll(this.scroller) {
        Column() {
          ForEach(this.bindings, (b: GpBinding, idx: number) => {
            Row() {
              Text(bindingDisplayText(b))
                .fontSize(13)
                .fontColor($r('app.color.settings_label_color'))
                .layoutWeight(1)
              if (this.listeningIdx === idx) {
                Text('请按键...')
                  .fontSize(12)
                  .fontColor($r('app.color.accent_color'))
                  .fontWeight(FontWeight.Bold)
              } else {
                Button('设置')
                  .height(26)
                  .fontSize(11)
                  .fontColor($r('app.color.accent_color'))
                  .backgroundColor(Color.Transparent)
                  .borderRadius(6)
                  .border({ width: 1, color: $r('app.color.accent_color') })
                  .padding({ left: 8, right: 8 })
                  .onClick(() => {
                    this.listeningIdx = idx;
                    this.listenSrcLabel = GP_SRC_LABELS[b.src] ?? b.src;
                  })
              }
            }
            .width('100%')
            .height(38)
            .alignItems(VerticalAlign.Center)
            .padding({ left: 12, right: 12 })
            if (idx < this.bindings.length - 1) {
              Row().width('100%').height(0.5).backgroundColor($r('app.color.settings_divider_color'))
            }
          }, (b: GpBinding, idx: number) => `${idx}_${b.src}_${b.mrKeys.length}`)
        }
        .width('100%')
      }
      .width('100%')
      .height(320)
      .scrollBar(BarState.Auto)

      Row() {
        Button('关闭')
          .width(100).height(36)
          .backgroundColor($r('app.color.settings_cancel_btn_bg'))
          .fontColor($r('app.color.settings_cancel_btn_fg'))
          .fontSize(14)
          .borderRadius(8)
          .onClick(() => {
            this.onConfirm(this.bindings);
            this.onClose();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: 8, bottom: 16 })
    }
    .width('88%')
    .backgroundColor($r('app.color.settings_dialog_bg'))
    .borderRadius(16)
    .focusScopeId('gpDialogGroup', true, false)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      if (this.listeningIdx < 0 || event.type !== KeyType.Down) return;
      const kc = event.keyCode;
      let src = '';
      if (kc === KeyCode.KEYCODE_DPAD_UP) src = 'dpad_up';
      else if (kc === KeyCode.KEYCODE_DPAD_DOWN) src = 'dpad_down';
      else if (kc === KeyCode.KEYCODE_DPAD_LEFT) src = 'dpad_left';
      else if (kc === KeyCode.KEYCODE_DPAD_RIGHT) src = 'dpad_right';
      else if (kc === KeyCode.KEYCODE_BUTTON_A) src = 'btn_a';
      else if (kc === KeyCode.KEYCODE_BUTTON_B) src = 'btn_b';
      else if (kc === KeyCode.KEYCODE_BUTTON_X) src = 'btn_x';
      else if (kc === KeyCode.KEYCODE_BUTTON_Y) src = 'btn_y';
      else if (kc === KeyCode.KEYCODE_BUTTON_L1) src = 'btn_l1';
      else if (kc === KeyCode.KEYCODE_BUTTON_R1) src = 'btn_r1';
      else if (kc === KeyCode.KEYCODE_BUTTON_START) src = 'btn_start';
      else if (kc === KeyCode.KEYCODE_BUTTON_SELECT) src = 'btn_select';
      if (src.length > 0) this.handleKeyResult(src);
    })
  }
}

@Builder
export function GamepadDialogBuilder($$: GamepadDialogParams) {
  GamepadDialogContent({
    initialBindings: $$.initialBindings,
    onConfirm: $$.onConfirm,
    onClose: $$.onClose
  })
}
