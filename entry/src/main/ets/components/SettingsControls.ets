import { preferences } from '@kit.ArkData';
import { gAbilityContext } from '../entryability/EntryAbility';

const CARD_RADIUS = 20;
const ROW_H = 56;
const PAD_H = 20;
const SEC_TOP = 20;
const SEC_BOT = 6;

export { CARD_RADIUS, ROW_H, PAD_H, SEC_TOP, SEC_BOT }

@ComponentV2
export struct SectionHeader {
  @Param title: ResourceStr = '';
  build() {
    Text(this.title)
      .fontSize(14)
      .fontColor($r('app.color.settings_desc_color'))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 4, top: SEC_TOP, bottom: SEC_BOT })
  }
}

@ComponentV2
export struct SDivider {
  build() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor($r('app.color.settings_divider_color'))
      .margin({ left: PAD_H, right: 0 })
  }
}

@ComponentV2
export struct SDesc {
  @Param text: ResourceStr = '';
  build() {
    Text(this.text)
      .fontSize(12)
      .fontColor($r('app.color.settings_desc_color'))
      .width('100%')
      .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 12 })
  }
}

@ComponentV2
export struct SRow {
  @BuilderParam content: () => void;
  @Param label: ResourceStr = '';
  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor($r('app.color.settings_label_color'))
        .layoutWeight(1)
      this.content()
    }
    .width('100%')
    .height(ROW_H)
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAD_H, right: PAD_H })
  }
}

@ComponentV2
export struct SSliderLabel {
  @Param label: ResourceStr = '';
  @Param valueText: string = '';
  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor($r('app.color.settings_label_color'))
        .layoutWeight(1)
      Text(this.valueText)
        .fontSize(13)
        .fontColor($r('app.color.btn_text_on_accent'))
        .fontWeight(FontWeight.Medium)
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(8)
        .backgroundColor($r('app.color.settings_slider_value_bg'))
    }
    .width('100%')
    .padding({ left: PAD_H, right: PAD_H, top: 12, bottom: 4 })
  }
}

@ComponentV2
export struct SSlider {
  @Param value: number = 0;
  @Param min: number = 0;
  @Param max: number = 1;
  @Param step: number = 0.05;
  @Event onChange: (v: number) => void = (_v: number) => {};
  build() {
    Row() {
      Slider({ value: this.value, min: this.min, max: this.max, step: this.step, style: SliderStyle.InSet })
        .width('100%')
        .trackColor($r('app.color.settings_slider_track'))
        .selectedColor($r('app.color.accent_color'))
        .blockColor($r('app.color.btn_text_on_accent'))
        .blockSize({ width: 20, height: 20 })
        .trackBorderRadius(10)
        .border({ width: 0 })
        .padding({ left: 0, right: 0 })
        .onChange((v: number) => { this.onChange(v); })
    }
    .padding({ left: PAD_H, right: PAD_H })
  }
}

@ComponentV2
export struct SSelect {
  @Param opts: SelectOption[] = [];
  @Param selected: number = 0;
  @Param value: string = '';
  @Event onSelect: (index: number) => void = (_index: number) => {};
  build() {
    Select(this.opts)
      .selected(this.selected)
      .value(this.value)
      .font({ size: 14 })
      .fontColor($r('app.color.settings_label_color'))
      .selectedOptionFont({ size: 15, weight: FontWeight.Bold })
      .selectedOptionFontColor($r('app.color.btn_text_on_accent'))
      .selectedOptionBgColor($r('app.color.accent_color'))
      .optionFont({ size: 14 })
      .optionFontColor($r('app.color.settings_desc_color'))
      .optionBgColor($r('app.color.settings_select_option_bg'))
      .menuBackgroundColor($r('app.color.settings_select_menu_bg'))
      .menuBackgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .backgroundColor($r('app.color.settings_select_bg'))
      .borderRadius(8)
      .onSelect((index: number) => { this.onSelect(index); })
  }
}

export interface DnsMapEntry {
  original: string;
  target: string;
  port: number;
  enabled: boolean;
}

const DNS_PREF_NAME = 'vmrp_settings';
const DNS_KEY_MAP = 'dns_map';

const DEFAULT_DNS_MAP: DnsMapEntry[] = [
  { original: 'wap.skmeg.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'rop.skymobiapp.com', target: '127.0.0.1', port: 18088, enabled: true },
  { original: 'spd.skymobiapp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'freeads.51mrp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'proxy.51mrp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'proxy2.51mrp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'help.proxy.51mrp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'dmrp.wapproxy.sky-mobi.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: '211.155.236.18', target: '159.75.119.124', port: 0, enabled: true },
];

// --- DNS 映射列表弹窗（@ComponentV2，自己管 preferences，不依赖父组件传数据） ---

@ComponentV2
export struct DnsMapListDialog {
  @Event onClose: () => void = () => {};

  // 组件内部可变状态
  @Local entries: DnsMapEntry[] = [];
  @Local mode: string = 'list';          // 'list' | 'edit' | 'add' | 'reset_confirm'
  @Local editDomain: string = '';
  @Local editTarget: string = '';
  @Local editPort: string = '';
  @Local editIndex: number = -1;         // -1=新增, >=0=编辑索引
  @Local validationError: string = '';

  aboutToAppear(): void {
    this.loadFromPrefs();
  }

  // ---------- preferences 读写 ----------
  private loadFromPrefs(): void {
    const ctx = gAbilityContext;
    if (ctx) {
      try {
        const pref = preferences.getPreferencesSync(ctx, { name: DNS_PREF_NAME });
        const raw = pref.getSync(DNS_KEY_MAP, '') as string;
        if (raw.length > 0) {
          const arr: Record<string, Object>[] = JSON.parse(raw) as Record<string, Object>[];
          if (arr.length > 0) {
            // save 时字段是 o/t/p/e，需要映射回 original/target/port/enabled
            this.entries = arr.map((item: Record<string, Object>): DnsMapEntry => ({
              original: (item['o'] ?? '') as string,
              target: (item['t'] ?? '') as string,
              port: (item['p'] ?? 0) as number,
              enabled: (item['e'] ?? true) as boolean
            }));
            return;
          }
        }
      } catch (_e) {}
    }
    this.entries = this.copyList(DEFAULT_DNS_MAP);
  }

  private saveToPrefs(): void {
    const ctx = gAbilityContext;
    if (!ctx) return;
    try {
      const pref = preferences.getPreferencesSync(ctx, { name: DNS_PREF_NAME });
      const json = JSON.stringify(this.entries.map((e: DnsMapEntry): Record<string, Object> => {
        const obj: Record<string, Object> = { 'o': e.original, 't': e.target, 'p': e.port, 'e': e.enabled };
        return obj;
      }));
      pref.putSync(DNS_KEY_MAP, json);
      pref.flush();
    } catch (_e) {}
  }

  private copyList(src: DnsMapEntry[]): DnsMapEntry[] {
    const list: DnsMapEntry[] = [];
    for (const e of src) {
      list.push({ original: e.original, target: e.target, port: e.port, enabled: e.enabled });
    }
    return list;
  }

  // ---------- 验证逻辑 ----------
  private validate(): boolean {
    const domain = this.editDomain.trim();
    const ip = this.editTarget.trim();
    if (domain.length === 0) {
      this.validationError = '域名不能为空';
      return false;
    }
    // 新增时检查域名唯一性
    if (this.editIndex < 0) {
      for (const e of this.entries) {
        if (e.original === domain) {
          this.validationError = '该域名已存在映射';
          return false;
        }
      }
    }
    if (ip.length === 0) {
      this.validationError = '目标 IP 不能为空';
      return false;
    }
    const ipParts = ip.split('.');
    if (ipParts.length !== 4) {
      this.validationError = 'IP 格式不合法 (需要 x.x.x.x)';
      return false;
    }
    let ipValid = true;
    for (const part of ipParts) {
      const n = parseInt(part, 10);
      if (isNaN(n) || n < 0 || n > 255 || part.length === 0) {
        ipValid = false;
        break;
      }
    }
    if (!ipValid) {
      this.validationError = 'IP 格式不合法';
      return false;
    }
    const port = parseInt(this.editPort, 10);
    if (this.editPort.length > 0 && (isNaN(port) || port < 1 || port > 65535)) {
      this.validationError = '端口范围 1-65535';
      return false;
    }
    return true;
  }

  // ---------- 操作方法 ----------
  private doDelete(index: number): void {
    const newList: DnsMapEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      if (i !== index) {
        newList.push(this.entries[i]);
      }
    }
    this.entries = newList;
    this.saveToPrefs();
  }

  private startAdd(): void {
    this.editDomain = '';
    this.editTarget = '';
    this.editPort = '';
    this.editIndex = -1;
    this.validationError = '';
    this.mode = 'add';
  }

  private startEdit(index: number): void {
    const e = this.entries[index];
    this.editDomain = e.original;
    this.editTarget = e.target;
    this.editPort = e.port > 0 ? `${e.port}` : '';
    this.editIndex = index;
    this.validationError = '';
    this.mode = 'edit';
  }

  private doConfirmEntry(): void {
    if (!this.validate()) {
      return;
    }
    const port = parseInt(this.editPort, 10);
    const entry: DnsMapEntry = {
      original: this.editDomain.trim(),
      target: this.editTarget.trim(),
      port: isNaN(port) ? 0 : port,
      enabled: true
    };
    // 构建新数组
    const newList: DnsMapEntry[] = [];
    let replaced = false;
    for (let i = 0; i < this.entries.length; i++) {
      if (this.editIndex >= 0 && i === this.editIndex) {
        newList.push(entry);
        replaced = true;
      } else if (this.entries[i].original === entry.original) {
        newList.push(entry);
        replaced = true;
      } else {
        const e = this.entries[i];
        newList.push({ original: e.original, target: e.target, port: e.port, enabled: e.enabled });
      }
    }
    if (!replaced) {
      newList.push(entry);
    }
    this.entries = newList;
    this.mode = 'list';
    this.validationError = '';
    this.saveToPrefs();
  }

  private doReset(): void {
    this.entries = this.copyList(DEFAULT_DNS_MAP);
    this.mode = 'list';
    this.saveToPrefs();
  }

  private confirmReset(): void {
    this.mode = 'reset_confirm';
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text($r('app.string.settings_section_dns'))
          .fontSize(18)
          .fontColor($r('app.color.settings_about_title'))
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        if (this.mode === 'list') {
          Text(`${this.entries.length} 条`)
            .fontSize(13)
            .fontColor($r('app.color.settings_desc_color'))
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 8 })

      // ========== 列表视图 ==========
      if (this.mode === 'list') {
        Scroll() {
          Column() {
            ForEach(this.entries, (entry: DnsMapEntry, index: number) => {
              Row() {
                Column() {
                  Text(entry.original)
                    .fontSize(13)
                    .fontColor($r('app.color.settings_label_color'))
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(entry.port > 0 ? `${entry.target}:${entry.port}` : entry.target)
                    .fontSize(12)
                    .fontColor($r('app.color.settings_desc_color'))
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Button() {
                  Text($r('app.string.btn_set'))
                    .fontSize(11)
                    .fontColor($r('app.color.accent_color'))
                }
                .height(26)
                .backgroundColor(Color.Transparent)
                .border({ width: 1, color: $r('app.color.accent_color'), radius: 6 })
                .padding({ left: 8, right: 8 })
                .onClick(() => { this.startEdit(index as number); })
                Button() {
                  Text($r('app.string.btn_delete'))
                    .fontSize(11)
                    .fontColor($r('app.color.accent_color'))
                }
                .height(26)
                .backgroundColor(Color.Transparent)
                .border({ width: 1, color: $r('app.color.settings_reset_btn_border'), radius: 6 })
                .padding({ left: 8, right: 8 })
                .margin({ left: 8 })
                .onClick(() => { this.doDelete(index as number); })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }, (_item: DnsMapEntry, index: number) => `${index}_${_item.original}`)
          }
        }
        .width('100%')
        .constraintSize({ maxHeight: 320 })
        .scrollBar(BarState.Auto)

        // 分隔线
        Row()
          .width('100%')
          .height(0.5)
          .backgroundColor($r('app.color.settings_divider_color'))
          .margin({ left: 16, right: 16 })

        // 底部操作栏
        Row() {
          Button($r('app.string.settings_btn_add_dns'))
            .height(32)
            .fontSize(12)
            .fontColor($r('app.color.btn_text_on_accent'))
            .fontWeight(FontWeight.Medium)
            .backgroundColor($r('app.color.accent_color'))
            .borderRadius(8)
            .onClick(() => { this.startAdd(); })
            .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
          Button($r('app.string.settings_btn_reset_dns'))
            .height(32)
            .fontSize(12)
            .fontColor($r('app.color.accent_color'))
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: $r('app.color.settings_reset_btn_border'), radius: 8 })
            .margin({ left: 8 })
            .onClick(() => { this.confirmReset(); })
            .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        // 关闭按钮
        Row() {
          Button($r('app.string.btn_cancel'))
            .width(100).height(36)
            .fontSize(14)
            .backgroundColor($r('app.color.settings_cancel_btn_bg')).fontColor($r('app.color.settings_cancel_btn_fg'))
            .borderRadius(8)
            .onClick(() => { this.onClose(); })
          Button($r('app.string.btn_confirm'))
            .width(100).height(36)
            .fontSize(14)
            .backgroundColor($r('app.color.accent_color')).fontColor($r('app.color.btn_text_on_accent'))
            .borderRadius(8)
            .margin({ left: 16 })
            .onClick(() => { this.onClose(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 16, right: 16, top: 4, bottom: 16 })
      }

      // ========== 编辑/添加视图 ==========
      if (this.mode === 'edit' || this.mode === 'add') {
        Text(this.mode === 'edit' ? $r('app.string.settings_dialog_title_edit_dns') : $r('app.string.settings_dialog_title_add_dns'))
          .fontSize(16)
          .fontColor($r('app.color.settings_about_title'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 8, bottom: 8 })

        TextInput({ placeholder: $r('app.string.settings_hint_domain'), text: this.editDomain })
          .onChange((v: string) => { this.editDomain = v; })
          .width('85%')
          .height(44)
          .fontSize(14)
          .backgroundColor($r('app.color.settings_dialog_input_bg'))
          .fontColor($r('app.color.settings_about_title'))
          .borderRadius(10)
          .margin({ bottom: 8 })

        TextInput({ placeholder: $r('app.string.settings_hint_target_ip'), text: this.editTarget })
          .onChange((v: string) => { this.editTarget = v; })
          .width('85%')
          .height(44)
          .fontSize(14)
          .backgroundColor($r('app.color.settings_dialog_input_bg'))
          .fontColor($r('app.color.settings_about_title'))
          .borderRadius(10)
          .margin({ bottom: 8 })

        TextInput({ placeholder: $r('app.string.settings_hint_target_port'), text: this.editPort })
          .onChange((v: string) => { this.editPort = v; })
          .width('85%')
          .height(44)
          .fontSize(14)
          .type(InputType.Number)
          .backgroundColor($r('app.color.settings_dialog_input_bg'))
          .fontColor($r('app.color.settings_about_title'))
          .borderRadius(10)
          .margin({ bottom: 8 })

        if (this.validationError.length > 0) {
          Text(this.validationError)
            .fontSize(12)
            .fontColor($r('app.color.accent_color'))
            .margin({ bottom: 8 })
        }

        Row() {
          Button($r('app.string.btn_cancel'))
            .width(100).height(36)
            .fontSize(13)
            .backgroundColor($r('app.color.settings_cancel_btn_bg')).fontColor($r('app.color.settings_cancel_btn_fg'))
            .onClick(() => { this.mode = 'list'; this.validationError = ''; })
          Button($r('app.string.btn_confirm'))
            .width(100).height(36)
            .fontSize(13)
            .backgroundColor($r('app.color.accent_color')).fontColor($r('app.color.btn_text_on_accent'))
            .onClick(() => { this.doConfirmEntry(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceEvenly)
        .margin({ top: 8, bottom: 16 })
      }

      // ========== 重置确认视图 ==========
      if (this.mode === 'reset_confirm') {
        Text($r('app.string.settings_dns_reset_confirm'))
          .fontSize(14)
          .fontColor($r('app.color.settings_label_color'))
          .margin({ top: 24, bottom: 20, left: 16, right: 16 })
        Row() {
          Button($r('app.string.btn_cancel'))
            .width(100).height(36)
            .fontSize(13)
            .backgroundColor($r('app.color.settings_cancel_btn_bg')).fontColor($r('app.color.settings_cancel_btn_fg'))
            .borderRadius(8)
            .onClick(() => { this.mode = 'list'; })
          Button($r('app.string.btn_confirm'))
            .width(100).height(36)
            .fontSize(13)
            .backgroundColor($r('app.color.accent_color')).fontColor($r('app.color.btn_text_on_accent'))
            .borderRadius(8)
            .margin({ left: 16 })
            .onClick(() => { this.doReset(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 16, right: 16, bottom: 16 })
      }
    }
    .width('90%')
    .backgroundColor($r('app.color.settings_dialog_bg'))
    .borderRadius(16)
  }
}

// DnsMapListDialog 参数接口（供 wrapBuilder 使用）
export interface DnsMapListDialogParams {
  onClose: () => void;
}

@Builder
export function DnsMapListDialogBuilder($$: DnsMapListDialogParams) {
  DnsMapListDialog({
    onClose: () => { $$.onClose(); }
  })
}
