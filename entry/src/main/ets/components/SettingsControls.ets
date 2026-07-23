const CARD_RADIUS = 20;
const ROW_H = 56;
const PAD_H = 20;
const SEC_TOP = 20;
const SEC_BOT = 6;

export { CARD_RADIUS, ROW_H, PAD_H, SEC_TOP, SEC_BOT }

@ComponentV2
export struct SectionHeader {
  @Param title: string = '';
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
  @Param text: string = '';
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
  @Param label: string = '';
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
  @Param label: string = '';
  @Param valueText: string = '';
  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor($r('app.color.settings_label_color'))
        .layoutWeight(1)
      Text(this.valueText)
        .fontSize(13)
        .fontColor('#FFFFFF')
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
        .blockColor('#FFFFFF')
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
      .selectedOptionFontColor('#FFFFFF')
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
