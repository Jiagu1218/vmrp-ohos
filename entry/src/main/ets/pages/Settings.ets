import { AppStorageV2 } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { AvoidData } from '../common/AvoidData';
import { HapticManager, HapticState, HapticStrength } from '../common/HapticManager';

const PREF_NAME = 'vmrp_settings';
const KEY_MEMORY = 'memory_mb';
const KEY_SENSITIVITY = 'motion_sensitivity';
const SENSITIVITY_MIN = 0.2;
const SENSITIVITY_MAX = 3.0;
const SENSITIVITY_STEP = 0.1;
const SENSITIVITY_DEFAULT = 1.0;
const MEMORY_OPTIONS: SelectOption[] = [
  { value: '1 MB' }, { value: '2 MB' }, { value: '4 MB' },
  { value: '6 MB' }, { value: '8 MB' }, { value: '16 MB' }
];
const MEMORY_VALUES: number[] = [1, 2, 4, 6, 8, 16];
const STRENGTH_OPTIONS: SelectOption[] = [
  { value: '轻柔' }, { value: '适中' }, { value: '强烈' }
];
const STRENGTH_VALUES: HapticStrength[] =
  [HapticStrength.LIGHT, HapticStrength.MEDIUM, HapticStrength.STRONG];

@ComponentV2
export struct SettingsPage {
  @Local memoryMb: number = 1;
  @Local selectedIndex: number = 0;
  @Local hapticEnabled: boolean = true;
  @Local strengthIndex: number = 1;
  @Local sensitivity: number = SENSITIVITY_DEFAULT;
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
  private hapticState: HapticState = HapticManager.getState();
  private pref: preferences.Preferences | null = null;
  private navPathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    this.hapticEnabled = this.hapticState.enabled;
    this.strengthIndex = STRENGTH_VALUES.indexOf(this.hapticState.strength);
    if (this.strengthIndex < 0) this.strengthIndex = 1;
    this.loadPrefs();
  }

  async loadPrefs(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) return;
      this.pref = await preferences.getPreferences(ctx, PREF_NAME);
      this.memoryMb = (await this.pref.get(KEY_MEMORY, 1)) as number;
      this.selectedIndex = MEMORY_VALUES.indexOf(this.memoryMb);
      if (this.selectedIndex < 0) this.selectedIndex = 0;
      this.sensitivity = (await this.pref.get(KEY_SENSITIVITY, SENSITIVITY_DEFAULT)) as number;
    } catch (_e) {
    }
  }

  async saveMemory(mb: number): Promise<void> {
    this.memoryMb = mb;
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx) {
        const pref = await preferences.getPreferences(ctx, PREF_NAME);
        await pref.put(KEY_MEMORY, mb);
        await pref.flush();
      }
    } catch (_e) {
    }
  }

  async saveHaptic(enabled: boolean): Promise<void> {
    this.hapticEnabled = enabled;
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      await HapticManager.saveEnabledPref(ctx, enabled);
    }
    if (enabled) {
      HapticManager.performClick();
    }
  }

  async saveStrength(index: number): Promise<void> {
    this.strengthIndex = index;
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      await HapticManager.saveStrengthPref(ctx, STRENGTH_VALUES[index]);
      HapticManager.performClick();
    }
  }

  async saveSensitivity(val: number): Promise<void> {
    this.sensitivity = val;
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx) {
        const pref = await preferences.getPreferences(ctx, PREF_NAME);
        await pref.put(KEY_SENSITIVITY, val);
        await pref.flush();
      }
    } catch (_e) {
    }
  }

  @Builder
  sectionHeader(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor('#8888AA')
      .width('100%')
      .padding({ left: 4, top: 16, bottom: 8 })
  }

  @Builder
  selectStyle(opts: SelectOption[], selected: number, value: string, onSelect: (index: number) => void) {
    Select(opts)
      .selected(selected)
      .value(value)
      .font({ size: 14 })
      .fontColor('#FFFFFF')
      .selectedOptionFont({ size: 15, weight: FontWeight.Bold })
      .selectedOptionFontColor('#FFFFFF')
      .selectedOptionBgColor('#E94560')
      .optionFont({ size: 14 })
      .optionFontColor('#CCCCCC')
      .optionBgColor('#0D0D1A')
      .menuBackgroundColor('#0D0D1A')
      .menuBackgroundBlurStyle(BlurStyle.NONE)
      .backgroundColor('#16213E')
      .borderRadius(8)
      .onSelect(onSelect)
  }

  build() {
    NavDestination() {
      Column() {
        Column() {
          Row() {
            Image($r('sys.media.ohos_ic_public_arrow_left'))
              .width(24)
              .height(24)
              .fillColor('#CCCCCC')
              .onClick(() => {
                if (this.navPathStack) {
                  this.navPathStack.pop();
                }
              })

            Text('设置')
              .fontSize(20)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .margin({ right: 24 })
          }
          .width('100%')
          .height(44)
          .padding({ left: 16, right: 16 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ top: this.avoidData.topVp })
        .backgroundColor('#0D0D1A')

        List({ space: 8 }) {
          ListItemGroup({ header: this.sectionHeader('模拟器') }) {
            ListItem() {
              Row() {
                Text('内存大小')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)

                Select(MEMORY_OPTIONS)
                  .selected(this.selectedIndex)
                  .value(`${this.memoryMb} MB`)
                  .font({ size: 14 })
                  .fontColor('#FFFFFF')
                  .selectedOptionFont({ size: 15, weight: FontWeight.Bold })
                  .selectedOptionFontColor('#FFFFFF')
                  .selectedOptionBgColor('#E94560')
                  .optionFont({ size: 14 })
                  .optionFontColor('#CCCCCC')
                  .optionBgColor('#0D0D1A')
                  .menuBackgroundColor('#0D0D1A')
                  .menuBackgroundBlurStyle(BlurStyle.NONE)
                  .backgroundColor('#16213E')
                  .borderRadius(8)
                  .onSelect((index: number) => {
                    this.selectedIndex = index;
                    this.saveMemory(MEMORY_VALUES[index]);
                  })
              }
              .width('100%')
              .height(56)
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16 })
            }

            ListItem() {
              Text('内存大小决定 MRP 可见的堆空间，需在下一次启动时生效。')
                .fontSize(12)
                .fontColor('#666688')
                .width('100%')
                .padding({ left: 16, right: 16, top: 4, bottom: 12 })
            }
          }
          .divider({ strokeWidth: 0.5, color: '#2A2A4E', startMargin: 16, endMargin: 16 })
          .backgroundColor('#1A1A2E')
          .borderRadius(16)

          ListItemGroup({ header: this.sectionHeader('交互') }) {
            ListItem() {
              Row() {
                Text('按键震动')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.hapticEnabled })
                  .selectedColor('#E94560')
                  .switchPointColor('#FFFFFF')
                  .onChange((isOn: boolean) => {
                    this.saveHaptic(isOn);
                  })
              }
              .width('100%')
              .height(56)
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16 })
            }

            ListItem() {
              Row() {
                Text('震动强度')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)

                this.selectStyle(STRENGTH_OPTIONS, this.strengthIndex,
                  STRENGTH_OPTIONS[this.strengthIndex].value as string,
                  (index: number) => {
                    this.saveStrength(index);
                  })
              }
              .width('100%')
              .height(56)
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16 })
              .enabled(this.hapticEnabled)
              .opacity(this.hapticEnabled ? 1 : 0.4)
            }

            ListItem() {
              Text('调节按键触控时的震动反馈力度，选择后即时体验。')
                .fontSize(12)
                .fontColor('#666688')
                .width('100%')
                .padding({ left: 16, right: 16, top: 4, bottom: 12 })
            }
          }
          .divider({ strokeWidth: 0.5, color: '#2A2A4E', startMargin: 16, endMargin: 16 })
          .backgroundColor('#1A1A2E')
          .borderRadius(16)

          ListItemGroup({ header: this.sectionHeader('动感') }) {
            ListItem() {
              Row() {
                Text('灵敏度')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)

                Text(`${this.sensitivity.toFixed(1)}x`)
                  .fontSize(14)
                  .fontColor('#E94560')
                  .width(40)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 0 })
            }

            ListItem() {
              Slider({
                value: this.sensitivity,
                min: SENSITIVITY_MIN,
                max: SENSITIVITY_MAX,
                step: SENSITIVITY_STEP
              })
                .width('100%')
                .trackColor('#2A2A4E')
                .selectedColor('#E94560')
                .blockColor('#FFFFFF')
                .blockBorderColor('#E94560')
                .blockBorderWidth(2)
                .blockSize({ width: 20, height: 20 })
                .padding({ left: 16, right: 16 })
                .onChange((value: number) => {
                  this.saveSensitivity(value);
                })
            }

            ListItem() {
              Text('调节加速度传感器灵敏度倍率，1.0 为默认值。值越大，动感游戏中球的移动越灵敏。需重启游戏后生效。')
                .fontSize(12)
                .fontColor('#666688')
                .width('100%')
                .padding({ left: 16, right: 16, top: 4, bottom: 12 })
            }
          }
          .divider({ strokeWidth: 0.5, color: '#2A2A4E', startMargin: 16, endMargin: 16 })
          .backgroundColor('#1A1A2E')
          .borderRadius(16)

          ListItemGroup({ header: this.sectionHeader('关于') }) {
            ListItem() {
              Column() {
                Text('VMRP')
                  .fontSize(18)
                  .fontColor('#FFFFFF')
                  .fontWeight(FontWeight.Bold)
                Text('MRP 模拟器')
                  .fontSize(13)
                  .fontColor('#8888AA')
                  .margin({ top: 2 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 16, right: 16, top: 16, bottom: 8 })
            }

            ListItem() {
              Text('VMRP 是一款基于 Mythroad 平台的 MRP 应用模拟器，可在 HarmonyOS 设备上运行经典的 MRP 小游戏与应用。')
                .fontSize(14)
                .fontColor('#8888AA')
                .lineHeight(22)
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 16 })
            }
          }
          .divider({ strokeWidth: 0.5, color: '#2A2A4E', startMargin: 16, endMargin: 16 })
          .backgroundColor('#1A1A2E')
          .borderRadius(16)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: 16, right: 16, top: 4 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0D0D1A')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .padding({ bottom: this.avoidData.bottomVp })
    }
    .hideTitleBar(true)
    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
    })
  }
}

@Builder
export function SettingsBuilder() {
  SettingsPage()
}
