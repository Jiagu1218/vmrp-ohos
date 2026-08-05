import { preferences } from '@kit.ArkData';
import { gAbilityContext } from '../entryability/EntryAbility';

const PREF_NAME = 'vmrp_settings';
const KEY_PRIVACY_AGREED = 'privacy_agreed';

export class PrivacyState {
  agreed: boolean = false;
}

export function isPrivacyAgreedSync(): boolean {
  const ctx = gAbilityContext;
  if (!ctx) return false;
  try {
    const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
    return pref.getSync(KEY_PRIVACY_AGREED, false) as boolean;
  } catch (_e) {
    return false;
  }
}

export async function setPrivacyAgreed(): Promise<void> {
  const ctx = gAbilityContext;
  if (!ctx) return;
  try {
    const pref = await preferences.getPreferences(ctx, PREF_NAME);
    await pref.put(KEY_PRIVACY_AGREED, true);
    await pref.flush();
  } catch (_e) {}
}

@ComponentV2
export struct PrivacyDialog {
  @Param onAgree: () => void = () => {};
  @Param onDisagree: () => void = () => {};
  @Local scrolledToEnd: boolean = false;

  build() {
    Column() {
      Text($r('app.string.privacy_dialog_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.settings_about_title'))
        .margin({ bottom: 16 })

      Scroll() {
        Text($r('app.string.privacy_dialog_content'))
          .fontSize(14)
          .fontColor($r('app.color.settings_about_subtitle'))
          .lineHeight(22)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .onReachEnd(() => {
        this.scrolledToEnd = true;
      })

      Row({ space: 12 }) {
        Button($r('app.string.privacy_btn_disagree'))
          .fontSize(16)
          .fontColor($r('app.color.settings_about_subtitle'))
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor($r('app.color.settings_about_subtitle'))
          .borderRadius(24)
          .layoutWeight(1)
          .height(44)
          .accessibilityText($r('app.string.privacy_btn_disagree'))
          .stateStyles({
            pressed: { .opacity(0.7) },
            focused: { .borderWidth(2).borderColor($r('app.color.accent_color')) },
            normal: { .opacity(1) }
          })
          .onClick(() => {
            this.onDisagree();
          })

        Button($r('app.string.privacy_btn_agree'))
          .fontSize(16)
          .fontColor($r('app.color.btn_text_on_accent'))
          .backgroundColor($r('app.color.accent_color'))
          .borderRadius(24)
          .layoutWeight(1)
          .height(44)
          .accessibilityText($r('app.string.privacy_btn_agree'))
          .stateStyles({
            pressed: { .opacity(0.7) },
            focused: { .borderWidth(2).borderColor($r('app.color.btn_text_on_accent')) },
            normal: { .opacity(1) }
          })
          .onClick(() => {
            this.onAgree();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding(24)
  }
}
