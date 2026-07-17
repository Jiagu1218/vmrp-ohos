import { hdsEffect } from '@kit.UIDesignKit';
import { curves, RectShape } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';

@ComponentV2
export struct ImmersiveLightWrapper {
  @BuilderParam content: () => void;
  @Param lightHeight: number = 100;
  @Param lightColor: ResourceColor = Color.White;
  @Param radius: number = 0;
  @Param bgColor: ResourceColor = '#12FFFFFF';
  @Param blurRadius: number = 24;
  @Local currentIntensity: number = 0;
  @Local lightIntensity: number = 2.5;
  @Local private fingerX: number = 0;
  @Local private fingerY: number = 0;
  @Local private isDark: boolean = true;

  aboutToAppear(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.isDark = context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (_e) {
      this.isDark = true;
    }
  }

  @Builder
  lightTracker() {
    Stack() {
      Flex()
        .size(this.currentIntensity > 0 ? { width: 1, height: 1 } : { width: 0, height: 0 })
        .backgroundColor(Color.Transparent)
        .visualEffect(
          new hdsEffect.HdsEffectBuilder()
            .pointLight({
              options: {
                color: this.lightColor,
                intensity: this.currentIntensity,
                height: this.lightHeight
              }
            })
            .buildEffect()
        )
        .position({ x: this.fingerX, y: this.fingerY })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack() {
      this.content()
    }
    .clip(true)
    .clipShape(new RectShape({ width: '100%', height: '100%', radius: this.radius }))
    .shadow({ radius: 36, color: $r('app.color.immersive_shadow') })
    .backgroundColor(this.bgColor)
    .visualEffect(
      new hdsEffect.HdsEffectBuilder()
        .pointLight({
          illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT,
        })
        .buildEffect()
    )
    .backdropBlur(this.blurRadius)
    .borderRadius(this.radius)
    .border({ width: this.isDark ? 0.5 : 1, color: $r('app.color.immersive_border_dark') })
    .overlay(this.lightTracker())
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseIn }, () => {
          this.currentIntensity = this.lightIntensity;
        });
        this.fingerX = event.touches[0].x;
        this.fingerY = event.touches[0].y;
      } else if (event.type === TouchType.Move) {
        this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion(0.5, 0.5) }, () => {
          this.fingerX = event.touches[0].x;
          this.fingerY = event.touches[0].y;
        });
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
          this.currentIntensity = 0;
        });
      }
    })
  }
}
