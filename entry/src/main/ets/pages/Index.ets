import { AppStorageV2, LengthMetrics } from '@kit.ArkUI';
import {
  HdsNavigation, HdsNavigationTitleMode,
  ScrollEffectType, hdsMaterial
} from '@kit.UIDesignKit';
import { i18n } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { VmrpAssets } from '../vmrp/VmrpAssets';
import { MrpInfoData, MrpInfo } from '../vmrp/MrpInfo';
import { gAbilityContext } from '../entryability/EntryAbility';
import { AvoidData } from '../common/AvoidData';
import { ImmersiveLightWrapper } from '../common/ImmersiveLightWrapper';
import { HapticManager } from '../common/HapticManager';

const CARD_RADIUS = 20;
const PLATFORM_NAMES: string[] = ['', 'MTK', '展讯', '', '', '', '', '', '', '斯凯'];
const DELETE_TRANSITION = TransitionEffect.OPACITY
  .combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
  .animation({ duration: 300, curve: Curve.EaseInOut });

interface MrpGroup {
  letter: string;
  items: MrpInfoData[];
}

const latnTransliterator: i18n.Transliterator = i18n.Transliterator.getInstance('Any-Latn');
const asciiTransliterator: i18n.Transliterator = i18n.Transliterator.getInstance('Latin-ASCII');

function emptyMrpInfoData(): MrpInfoData {
  const d: MrpInfoData = {
    filename: '', appname: '', appid: 0, version: 0,
    vendor: '', description: '', screenW: 240, screenH: 320,
    platform: 0, fileSize: 0, filePath: '', mtime: 0
  };
  return d;
}

function getPinyinInitial(name: string): string {
  if (name.length === 0) return '#';
  const ch = name.charAt(0).toUpperCase();
  if (ch >= 'A' && ch <= 'Z') return ch;
  try {
    const latn = latnTransliterator.transform(name.charAt(0));
    const ascii = asciiTransliterator.transform(latn);
    const letter = ascii.charAt(0).toUpperCase();
    if (letter >= 'A' && letter <= 'Z') return letter;
  } catch (_e) {}
  return '#';
}

function groupByLetter(list: MrpInfoData[]): MrpGroup[] {
  const map: Record<string, MrpInfoData[]> = {};
  const order: string[] = [];
  for (const item of list) {
    const letter = getPinyinInitial(item.appname);
    if (!map[letter]) {
      map[letter] = [];
      order.push(letter);
    }
    map[letter].push(item);
  }
  order.sort();
  const groups: MrpGroup[] = [];
  for (const letter of order) {
    groups.push({ letter: letter, items: map[letter] });
  }
  return groups;
}

function buildIndexArray(groups: MrpGroup[]): string[] {
  const arr: string[] = [];
  for (const g of groups) {
    arr.push(g.letter);
  }
  if (arr.length === 0) return ['#'];
  return arr;
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
  @Local sortMode: number = 0;
  @Local selectedIndex: number = 0;
  @Local searchMode: boolean = false;
  @Local searchQuery: string = '';
  private navPathStack: NavPathStack = new NavPathStack();
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
  private listScroller: Scroller = new Scroller();
  private rawList: MrpInfoData[] = [];

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
      this.rawList = list;
      this.applySort();
    } catch (_e) {
      this.rawList = [];
      this.mrpList = [];
    }
    this.isScanning = false;
  }

  private applySort(): void {
    let list = [...this.rawList];
    if (this.searchQuery.length > 0) {
      const q = this.searchQuery.toLowerCase();
      list = list.filter((item: MrpInfoData) => {
        return item.appname.toLowerCase().indexOf(q) >= 0 ||
          item.vendor.toLowerCase().indexOf(q) >= 0 ||
          item.filename.toLowerCase().indexOf(q) >= 0;
      });
    }
    if (this.sortMode === 0) {
      list.sort((a: MrpInfoData, b: MrpInfoData) => b.mtime - a.mtime);
    } else {
      list.sort((a: MrpInfoData, b: MrpInfoData) => {
        const na = a.appname.toLowerCase();
        const nb = b.appname.toLowerCase();
        if (na < nb) return -1;
        if (na > nb) return 1;
        return 0;
      });
    }
    this.mrpList = list;
  }

  private toggleSort(): void {
    this.sortMode = this.sortMode === 0 ? 1 : 0;
    this.applySort();
  }

  private toggleSearch(): void {
    this.searchMode = !this.searchMode;
    if (!this.searchMode) {
      this.searchQuery = '';
      this.applySort();
    }
  }

  private onSearchInput(query: string): void {
    this.searchQuery = query;
    this.applySort();
  }

  private launchMrp(mrpPath: string): void {
    this.navPathStack.pushPathByName('Emulator', mrpPath);
  }

  private openSettings(): void {
    this.navPathStack.pushPathByName('Settings', null);
  }

  private deleteMrp(item: MrpInfoData): void {
    HapticManager.performClick();
    try {
      fs.unlinkSync(item.filePath);
    } catch (_e) {
      return;
    }
    this.rawList = this.rawList.filter((i: MrpInfoData) => i.filePath !== item.filePath);
    this.getUIContext()?.animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
      this.applySort();
    });
  }

  @Builder
  swipeDeleteButton(item: MrpInfoData) {
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(18)
          .fontColor([Color.White])
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.accent_color'))
      .onClick(() => this.deleteMrp(item))
    }
    .width(70)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  groupHeader(letter: string) {
    Text(letter)
      .fontSize(14)
      .fontColor($r('app.color.settings_desc_color'))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 20, top: 16, bottom: 4 })
  }

  build() {
    HdsNavigation(this.navPathStack) {
      Stack({ alignContent: Alignment.End }) {
        List({ space: 8, scroller: this.listScroller }) {
          if (this.searchMode) {
            ListItem() {
              Search({ value: this.searchQuery, placeholder: '搜索游戏名称、厂商...' })
                .width('100%')
                .height(40)
                .backgroundColor($r('app.color.settings_card_bg'))
                .placeholderColor($r('app.color.settings_desc_color'))
                .placeholderFont({ size: 14 })
                .textFont({ size: 14 })
                .fontColor($r('app.color.settings_about_title'))
                .onSubmit((value: string) => this.onSearchInput(value))
                .onChange((value: string) => this.onSearchInput(value))
            }
            .padding({ left: 16, right: 16 })
          }
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
            } else if (this.sortMode === 1 && this.searchQuery.length === 0) {
              ForEach(groupByLetter(this.mrpList), (group: MrpGroup) => {
                ListItemGroup({ header: this.groupHeader(group.letter), space: 8 }) {
                  ForEach(group.items, (item: MrpInfoData) => {
                    ListItem() {
                      MrpCard({
                        info: item,
                        onLaunch: (path: string) => this.launchMrp(path)
                      })
                    }
                    .padding({ left: 16, right: 16 })
                    .swipeAction({ end: this.swipeDeleteButton(item) })
                    .transition(DELETE_TRANSITION)
                  }, (item: MrpInfoData) => item.filePath)
                }
              }, (group: MrpGroup) => group.letter)
            } else {
              ForEach(this.mrpList, (item: MrpInfoData) => {
                ListItem() {
                  MrpCard({
                    info: item,
                    onLaunch: (path: string) => this.launchMrp(path)
                  })
                }
                .padding({ left: 16, right: 16 })
                .swipeAction({ end: this.swipeDeleteButton(item) })
                .transition(DELETE_TRANSITION)
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
          .onScrollIndex((start: number) => {
            if (this.sortMode !== 1 || this.mrpList.length === 0) return;
            const groups = groupByLetter(this.mrpList);
            if (start >= 0 && start < groups.length) {
              const letter = groups[start].letter;
              const idx = this.currentIndexArray.indexOf(letter);
              if (idx >= 0) {
                this.selectedIndex = idx;
              }
            }
          })

          if (this.sortMode === 1 && this.mrpList.length > 0 && this.searchQuery.length === 0) {
            AlphabetIndexer({ arrayValue: this.currentIndexArray, selected: this.selectedIndex })
              .color($r('app.color.settings_desc_color'))
              .selectedColor($r('app.color.accent_color'))
              .popupColor($r('app.color.accent_color'))
              .selectedBackgroundColor($r('app.color.settings_card_bg'))
              .popupBackground($r('app.color.settings_card_bg'))
              .usingPopup(true)
              .font({ size: 10 })
              .selectedFont({ size: 12, weight: FontWeight.Bold })
              .popupFont({ size: 24, weight: FontWeight.Bold })
              .itemSize(24)
              .alignStyle(IndexerAlign.Left)
              .popupPosition({ x: -72, y: 0 })
              .width(24)
              .height('100%')
              .margin({ right: 4 })
              .onSelect((index: number) => {
                const groups = groupByLetter(this.mrpList);
                if (index >= 0 && index < groups.length) {
                  this.listScroller.scrollToIndex(index, false, ScrollAlign.CENTER);
                }
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopEnd)
      }
      .titleBar({
      content: {
        title: { mainTitle: 'MRP 游戏库' },
        menu: {
          value: [
            {
              content: {
                label: '搜索',
                icon: $r('sys.symbol.magnifyingglass'),
                isEnabled: true,
                action: () => this.toggleSearch()
              }
            },
            {
              content: {
                label: this.sortMode === 0 ? '按时间' : '按名称',
                icon: $r('sys.symbol.sort'),
                isEnabled: true,
                action: () => this.toggleSort()
              }
            },
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

  private get currentIndexArray(): string[] {
    return buildIndexArray(groupByLetter(this.mrpList));
  }
}
