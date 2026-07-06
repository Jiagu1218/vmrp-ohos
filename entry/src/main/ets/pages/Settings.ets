import { AppStorageV2 } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { AvoidData } from '../common/AvoidData';

const PREF_NAME = 'vmrp_settings';
const KEY_MEMORY = 'memory_mb';
const MEMORY_OPTIONS: SelectOption[] = [
  { value: '1 MB' }, { value: '2 MB' }, { value: '4 MB' },
  { value: '6 MB' }, { value: '8 MB' }, { value: '16 MB' }
];
const MEMORY_VALUES: number[] = [1, 2, 4, 6, 8, 16];

@ComponentV2
export struct SettingsPage {
  @Local memoryMb: number = 1;
  @Local selectedIndex: number = 0;
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
  private pref: preferences.Preferences | null = null;
  private navPathStack: NavPathStack | null = null;

  aboutToAppear(): void {
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
    } catch (_e) {
    }
  }

  async saveMemory(mb: number): Promise<void> {
    this.memoryMb = mb;
    try {
      if (this.pref) {
        await this.pref.put(KEY_MEMORY, mb);
        await this.pref.flush();
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
