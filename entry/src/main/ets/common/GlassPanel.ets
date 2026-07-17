@ComponentV2
export struct GlassPanel {
  @BuilderParam content: () => void;
  @Param blurRadius: number = 24;
  @Param panelBorderRadius: number = 16;
  @Param panelBorderColor: ResourceColor = '#2A2A4E';
  @Param panelBgColor: ResourceColor = '#12FFFFFF';
  @Param panelBorderWidth: number = 0.5;

  build() {
    Stack() {
      this.content()
    }
    .backdropBlur(this.blurRadius)
    .backgroundColor(this.panelBgColor)
    .borderRadius(this.panelBorderRadius)
    .border({ width: this.panelBorderWidth, color: this.panelBorderColor })
    .clip(true)
  }
}
