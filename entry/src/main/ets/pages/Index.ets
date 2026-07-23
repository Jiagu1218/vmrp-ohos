import { AppStorageV2, LengthMetrics, SymbolGlyphModifier, window, display } from '@kit.ArkUI';
import {
  HdsNavigation, HdsNavigationTitleMode,
  HdsTabs, HdsTabsController,
  ScrollEffectType, hdsMaterial
} from '@kit.UIDesignKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { VmrpAssets } from '../vmrp/VmrpAssets';
import { MrpInfoData, MrpInfo } from '../vmrp/MrpInfo';
import { gAbilityContext } from '../entryability/EntryAbility';
import { AvoidData } from '../common/AvoidData';
import { ImmersiveLightWrapper } from '../common/ImmersiveLightWrapper';
import { HapticManager } from '../common/HapticManager';
import { FlatItem, MrpGroup, CARD_RADIUS, DELETE_TRANSITION, emptyMrpInfoData, groupByLetter, buildIndexArray } from '../model/MrpListModel';
import { FavoriteStore } from '../model/FavoriteStore';

@Entry
@ComponentV2
struct Index {
  @Local mrpList: MrpInfoData[] = [];
  @Local groupedItems: MrpGroup[] = [];
  @Local indexArray: string[] = ['#'];
  @Local isScanning: boolean = false;
  @Local isRefreshing: boolean = false;
  @Local sortMode: number = 0;
  @Local selectedIndex: number = 0;
  @Local searchMode: boolean = false;
  @Local searchQuery: string = '';
  @Local flatItems: FlatItem[] = [];
  @Local currentTab: number = 0;
  @Local titleBarOffset: number = 96;
  private navPathStack: NavPathStack = new NavPathStack();
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
  private listScroller: Scroller = new Scroller();
  private favScroller: Scroller = new Scroller();
  private hdsTabsController: HdsTabsController = new HdsTabsController();
  private rawList: MrpInfoData[] = [];
  private favStore: FavoriteStore = new FavoriteStore();

  aboutToAppear(): void {
    const ctx = gAbilityContext;
    if (ctx) {
      this.favStore = FavoriteStore.loadSync(ctx);
      try {
        const win: window.Window = ctx.windowStage.getMainWindowSync();
        const topPx: number = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
        const density: number = display.getDefaultDisplaySync().densityPixels;
        this.titleBarOffset = topPx / density + 48;
      } catch (_e) {}
    }
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
      this.flatItems = [];
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
    this.rebuildGroups();
    this.rebuildFlatItems();
  }

  private rebuildGroups(): void {
    if (this.sortMode === 1 && this.searchQuery.length === 0 && this.currentTab === 0) {
      this.groupedItems = groupByLetter(this.mrpList);
      this.indexArray = buildIndexArray(this.groupedItems);
    } else {
      this.groupedItems = [];
      this.indexArray = ['#'];
    }
  }

  private rebuildFlatItems(): void {
    const items: FlatItem[] = [];
    if (this.currentTab === 1) {
      for (const card of this.mrpList) {
        if (this.favStore.isFavorite(card.filePath)) {
          items.push({ type: 'card', letter: '', data: card, key: card.filePath });
        }
      }
    } else if (this.sortMode === 1 && this.searchQuery.length === 0) {
      for (const group of this.groupedItems) {
        items.push({ type: 'header', letter: group.letter, data: emptyMrpInfoData(), key: 'h_' + group.letter });
        for (const card of group.items) {
          items.push({ type: 'card', letter: '', data: card, key: card.filePath });
        }
      }
    } else {
      for (const card of this.mrpList) {
        items.push({ type: 'card', letter: '', data: card, key: card.filePath });
      }
    }
    this.flatItems = items;
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

  private launchMrp(item: MrpInfoData): void {
    this.navPathStack.pushPathByName('Emulator', item.filePath);
  }

  private openSettings(): void {
    this.navPathStack.pushPathByName('Settings', null);
  }

  private toggleFavorite(item: MrpInfoData): void {
    HapticManager.performClick();
    this.favStore.toggle(item.filePath);
    const ctx = gAbilityContext;
    if (ctx) {
      this.favStore.saveSync(ctx);
    }
    this.rebuildFlatItems();
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

  private formatSize(bytes: number): string {
    if (bytes <= 0) return '';
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
    return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
  }

  private getBaseName(path: string): string {
    const slash = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  @Builder
  swipeEndBuilder(item: MrpInfoData, isFav: boolean) {
    Row() {
      Column() {
        SymbolGlyph(isFav ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(18)
          .fontColor([isFav ? Color.Red : Color.White])
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(isFav ? '#33FFFFFF' : '#555577')
      .onClick(() => this.toggleFavorite(item))

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
      .margin({ left: 8 })
      .onClick(() => this.deleteMrp(item))
    }
  }

  @Builder
  swipeDeleteOnlyBuilder(item: MrpInfoData) {
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
  }

  @Builder
  emptyStateBuilder() {
    Column() {
      Text(this.currentTab === 1 ? '暂无收藏' : '暂无游戏')
        .fontSize(18)
        .fontColor($r('app.color.settings_about_title'))
        .fontWeight(FontWeight.Medium)
      Text(this.currentTab === 1 ? '在游戏库中左划添加收藏' : '在设置中导入 .mrp 游戏文件')
        .fontSize(13)
        .fontColor($r('app.color.settings_desc_color'))
        .margin({ top: 6 })
      if (this.currentTab === 0) {
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
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 60, bottom: 60 })
  }

  @Builder
  cardItemBuilder(ri: RepeatItem<FlatItem>) {
    ListItem() {
      Column() {
        ImmersiveLightWrapper({
          radius: CARD_RADIUS,
          lightHeight: 80,
          bgColor: $r('app.color.settings_card_bg'),
          blurRadius: 30
        }) {
          Column() {
            Row() {
              if (this.currentTab === 0 && this.favStore.isFavorite(ri.item.data.filePath)) {
                SymbolGlyph($r('sys.symbol.heart_fill'))
                  .fontSize(14)
                  .fontColor([Color.Red])
                  .margin({ right: 6 })
              }
              Text(ri.item.data.appname)
                .fontSize(17)
                .fontColor($r('app.color.settings_about_title'))
                .fontWeight(FontWeight.Bold)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(`v${ri.item.data.version}`)
                .fontSize(12)
                .fontColor($r('app.color.settings_desc_color'))
                .margin({ left: 8 })
            }
            .width('100%')

            if (ri.item.data.vendor.length > 0) {
              Text(ri.item.data.vendor)
                .fontSize(12)
                .fontColor($r('app.color.settings_desc_color'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 4 })
            }

            if (ri.item.data.description.length > 0) {
              Text(ri.item.data.description)
                .fontSize(13)
                .fontColor($r('app.color.settings_desc_color'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 6 })
            }

            Row() {
              Text(ri.item.data.filename)
                .fontSize(12)
                .fontColor($r('app.color.settings_desc_color'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(this.getBaseName(ri.item.data.filePath))
                .fontSize(12)
                .fontColor($r('app.color.settings_desc_color'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: 12 })
              Text(this.formatSize(ri.item.data.fileSize))
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
        this.launchMrp(ri.item.data);
      })
    }
    .padding({ left: 16, right: 16 })
    .swipeAction({ end: { builder: (): void => { this.swipeEndBuilder(ri.item.data, this.favStore.isFavorite(ri.item.data.filePath)); }, actionAreaDistance: 56 } })
    .transition(DELETE_TRANSITION)
  }

  @Builder
  gameLibraryContent() {
    Stack({ alignContent: Alignment.End }) {
      Refresh({ refreshing: $$this.isRefreshing }) {
        List({ space: 8, scroller: this.listScroller }) {
          ListItem() {
            Column().width('100%').height(this.titleBarOffset)
          }
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
          } else if (this.flatItems.length === 0) {
            ListItem() {
              this.emptyStateBuilder()
            }
          } else {
            Repeat<FlatItem>(this.flatItems)
              .each((ri: RepeatItem<FlatItem>) => {
                ListItem() {
                  Text(ri.item.data.appname)
                }
              })
              .key((item: FlatItem): string => item.key)
              .templateId((item: FlatItem): string => item.type)
              .template('header', (ri: RepeatItem<FlatItem>) => {
                ListItem() {
                  Text(ri.item.letter)
                    .fontSize(14)
                    .fontColor($r('app.color.settings_desc_color'))
                    .fontWeight(FontWeight.Medium)
                    .width('100%')
                    .padding({ left: 20, top: 16, bottom: 4 })
                }
              })
              .template('card', (ri: RepeatItem<FlatItem>) => {
                this.cardItemBuilder(ri)
              }, { cachedCount: 5 })
              .virtualScroll({ totalCount: this.flatItems.length })
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .padding({ left: 0, right: 0, top: 4, bottom: 84 })
        .clip(false)
        .cachedCount(5, true)
        .onScrollIndex((start: number) => {
          if (this.sortMode !== 1 || this.flatItems.length === 0) return;
          const offset = this.searchMode ? 1 : 0;
          const idx = start - offset;
          if (idx < 0 || idx >= this.flatItems.length) return;
          const item = this.flatItems[idx];
          if (item.type === 'header') {
            const ai = this.indexArray.indexOf(item.letter);
            if (ai >= 0) this.selectedIndex = ai;
          } else if (item.type === 'card') {
            for (let i = idx; i >= 0; i--) {
              if (this.flatItems[i].type === 'header') {
                const ai = this.indexArray.indexOf(this.flatItems[i].letter);
                if (ai >= 0) this.selectedIndex = ai;
                break;
              }
            }
          }
        })
      }
      .refreshOffset(64)
      .pullToRefresh(true)
      .backgroundColor(Color.Transparent)
      .clip(false)
      .onRefreshing(() => {
        this.scanMrpFiles();
        this.isRefreshing = false;
      })

      if (this.sortMode === 1 && this.flatItems.length > 0 && this.searchQuery.length === 0) {
        AlphabetIndexer({ arrayValue: this.indexArray, selected: this.selectedIndex })
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
            const letter = this.indexArray[index];
            const idxOffset = 1 + (this.searchMode ? 1 : 0);
            const flatIdx = this.flatItems.findIndex((fi: FlatItem) =>
              fi.type === 'header' && fi.letter === letter);
            if (flatIdx >= 0) {
              this.listScroller.scrollToIndex(flatIdx + idxOffset, false, ScrollAlign.CENTER);
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopEnd)
    .backgroundColor(Color.Transparent)
    .clip(false)
  }

  @Builder
  favoritesContent() {
    Refresh({ refreshing: $$this.isRefreshing }) {
      List({ space: 8, scroller: this.favScroller }) {
        ListItem() {
          Column().width('100%').height(this.titleBarOffset)
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
        } else if (this.flatItems.length === 0) {
          ListItem() {
            this.emptyStateBuilder()
          }
        } else {
          Repeat<FlatItem>(this.flatItems)
            .each((ri: RepeatItem<FlatItem>) => {
              ListItem() {
                Text(ri.item.data.appname)
              }
            })
            .key((item: FlatItem): string => item.key)
            .template('card', (ri: RepeatItem<FlatItem>) => {
              this.cardItemBuilder(ri)
            }, { cachedCount: 5 })
            .virtualScroll({ totalCount: this.flatItems.length })
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .padding({ left: 0, right: 0, top: 4, bottom: 84 })
      .clip(false)
      .cachedCount(5, true)
    }
    .refreshOffset(64)
    .pullToRefresh(true)
    .backgroundColor(Color.Transparent)
    .clip(false)
    .onRefreshing(() => {
      this.scanMrpFiles();
      this.isRefreshing = false;
    })
    .width('100%')
    .height('100%')
  }

  build() {
    HdsNavigation(this.navPathStack) {
      HdsTabs({ controller: this.hdsTabsController }) {
        TabContent() {
          this.gameLibraryContent()
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.gamecontroller'))
            .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
            .fontColor([$r('sys.color.ohos_id_color_bottom_tab_icon_off')]),
          selected: new SymbolGlyphModifier($r('sys.symbol.gamecontroller'))
            .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
            .fontColor([$r('app.color.accent_color')])
        }, '游戏库'))

        TabContent() {
          this.favoritesContent()
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.heart'))
            .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
            .fontColor([$r('sys.color.ohos_id_color_bottom_tab_icon_off')]),
          selected: new SymbolGlyphModifier($r('sys.symbol.heart'))
            .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
            .fontColor([$r('app.color.accent_color')])
        }, '收藏'))
      }
      .barOverlap(true)
      .vertical(false)
      .barPosition(BarPosition.End)
      .scrollable(false)
      .animationDuration(0)
      .onChange((index: number) => {
        HapticManager.performClick();
        this.currentTab = index;
        this.applySort();
        if (index === 0) {
          this.listScroller.scrollToIndex(0, false, ScrollAlign.START);
        } else {
          this.favScroller.scrollToIndex(0, false, ScrollAlign.START);
        }
      })
      .clip(false)
      .barFloatingStyle({
        barBottomMargin: 28,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
    }
    .titleBar({
      content: {
        title: { mainTitle: this.currentTab === 1 ? '收藏' : 'MRP 游戏库' },
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
        originalStyle: {
          backgroundStyle: { backgroundColor: Color.Transparent }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
      },
      enableComponentSafeArea: false,
      avoidLayoutSafeArea: true
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .backgroundColor($r('app.color.immersive_bg'))
    .bindToScrollable([this.listScroller, this.favScroller])
    .mode(NavigationMode.Stack)
  }
}
