import { AppStorageV2, LengthMetrics } from '@kit.ArkUI';
import {
  HdsNavigation, HdsNavigationTitleMode,
  ScrollEffectType, hdsMaterial
} from '@kit.UIDesignKit';
import { VmrpAssets } from '../vmrp/VmrpAssets';
import { MrpInfoData, MrpInfo } from '../vmrp/MrpInfo';
import { gAbilityContext } from '../entryability/EntryAbility';
import { AvoidData } from '../common/AvoidData';
import { ImmersiveLightWrapper } from '../common/ImmersiveLightWrapper';
import { HapticManager } from '../common/HapticManager';

const CARD_RADIUS = 20;
const PLATFORM_NAMES: string[] = ['', 'MTK', '展讯', '', '', '', '', '', '', '斯凯'];

function emptyMrpInfoData(): MrpInfoData {
  const d: MrpInfoData = {
    filename: '', appname: '', appid: 0, version: 0,
    vendor: '', description: '', screenW: 240, screenH: 320,
    platform: 0, fileSize: 0, filePath: ''
  };
  return d;
}


@ComponentV2
struct MrpCard {
  @Param info: MrpInfoData = emptyMrpInfoData();
  @Param onLaunch: (path: string) => void = () => {};

  build() {
    Column() {
      ImmersiveLightWrapper({
        radius: CARD_RADIUS,
        lightHeight: 80,
        bgColor: $r('app.color.settings_card_bg'),
        blurRadius: 30
      }) {
        Column() {
          Row() {
            Text(this.info.appname)
              .fontSize(17)
              .fontColor($r('app.color.settings_about_title'))
              .fontWeight(FontWeight.Bold)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(`v${this.info.version}`)
              .fontSize(12)
              .fontColor($r('app.color.settings_desc_color'))
              .margin({ left: 8 })
          }
          .width('100%')

          if (this.info.vendor.length > 0) {
            Text(this.info.vendor)
              .fontSize(12)
              .fontColor($r('app.color.settings_desc_color'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 4 })
          }

          if (this.info.description.length > 0) {
            Text(this.info.description)
              .fontSize(13)
              .fontColor($r('app.color.settings_desc_color'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 6 })
          }

          Row() {
            Text(`${this.info.screenW}×${this.info.screenH}`)
              .fontSize(12)
              .fontColor($r('app.color.settings_desc_color'))
            if (this.info.platform > 0 && this.info.platform < PLATFORM_NAMES.length) {
              Text(PLATFORM_NAMES[this.info.platform])
                .fontSize(12)
                .fontColor($r('app.color.settings_desc_color'))
                .margin({ left: 12 })
            }
            Text(this.formatSize(this.info.fileSize))
              .fontSize(12)
              .fontColor($r('app.color.settings_desc_color'))
              .margin({ left: 12 })
          }
          .width('100%')
          .margin({ top: 8 })
        }
        .padding(16)
        .width('100%')
      }
    }
    .width('100%')
    .onClick(() => {
      HapticManager.performClick();
      this.onLaunch(this.info.filePath);
    })
  }

  private formatSize(bytes: number): string {
    if (bytes <= 0) return '';
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
    return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
  }
}

@Entry
@ComponentV2
struct Index {
  @Local mrpList: MrpInfoData[] = [];
  @Local isScanning: boolean = false;
  private navPathStack: NavPathStack = new NavPathStack();
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
  private listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.scanMrpFiles();
  }

  onPageShow(): void {
    this.scanMrpFiles();
  }

  private scanMrpFiles(): void {
    const ctx = gAbilityContext;
    if (!ctx) return;
    this.isScanning = true;
    try {
      const files = VmrpAssets.listMrpFiles(ctx);
      const list: MrpInfoData[] = [];
      for (const filePath of files) {
        const info = MrpInfo.parse(filePath);
        if (info !== null) {
          list.push(info);
        }
      }
      this.mrpList = list;
    } catch (_e) {
      this.mrpList = [];
    }
    this.isScanning = false;
  }

  private launchMrp(mrpPath: string): void {
    this.navPathStack.pushPathByName('Emulator', mrpPath);
  }

  private openSettings(): void {
    this.navPathStack.pushPathByName('Settings', null);
  }

  build() {
    HdsNavigation(this.navPathStack) {
      List({ space: 8, scroller: this.listScroller }) {
        if (this.isScanning) {
          ListItem() {
            Column() {
              LoadingProgress()
                .width(40)
                .height(40)
                .color($r('app.color.accent_color'))
              Text('扫描中...')
                .fontSize(13)
                .fontColor($r('app.color.settings_desc_color'))
                .margin({ top: 12 })
            }
            .width('100%')
            .height(200)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
        } else if (this.mrpList.length === 0) {
          ListItem() {
            Column() {
              Text('暂无游戏')
                .fontSize(18)
                .fontColor($r('app.color.settings_about_title'))
                .fontWeight(FontWeight.Medium)
              Text('在设置中导入 .mrp 游戏文件')
                .fontSize(13)
                .fontColor($r('app.color.settings_desc_color'))
                .margin({ top: 6 })
              Column() {
                ImmersiveLightWrapper({ radius: 22, lightHeight: 80 }) {
                  Stack() {
                    Text('前往设置')
                      .fontSize(14)
                      .fontColor('#FFFFFF')
                      .fontWeight(FontWeight.Medium)
                  }
                  .width(140)
                  .height(44)
                  .backgroundColor(Color.Transparent)
                }
              }
              .margin({ top: 24 })
              .onClick(() => { HapticManager.performClick(); this.openSettings(); })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 60, bottom: 60 })
          }
        } else {
          ForEach(this.mrpList, (item: MrpInfoData) => {
            ListItem() {
              MrpCard({
                info: item,
                onLaunch: (path: string) => this.launchMrp(path)
              })
            }
            .padding({ left: 16, right: 16 })
          }, (item: MrpInfoData) => item.filePath)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 0, right: 0, top: 4, bottom: this.avoidData.bottomVp })
      .clip(false)
      .cachedCount(2, true)
      .expandSafeArea()
    }
    .width('100%')
    .height('100%')
    .titleBar({
      content: {
        title: { mainTitle: 'MRP 游戏库' },
        menu: {
          value: [
            {
              content: {
                label: '设置',
                icon: $r('sys.symbol.gearshape'),
                isEnabled: true,
                action: () => this.openSettings()
              }
            }
          ]
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20),
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
      },
      enableComponentSafeArea: true,
      avoidLayoutSafeArea: true
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .backgroundColor($r('app.color.immersive_bg'))
    .bindToScrollable([this.listScroller])
    .mode(NavigationMode.Stack)
  }
}
