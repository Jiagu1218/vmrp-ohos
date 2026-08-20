/**
 * StoreControls.ets - 商店专用 UI 组件
 *
 * 包含 StoreCard, StoreSearch, StoreDetailDialog, StoreUploadDialog 组件。
 * 使用 @ComponentV2 模式，与项目现有组件风格一致。
 */
import { ComponentContent } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { StoreService } from '../vmrp/StoreService';
import {
  StoreApp, StoreAppDetail, StoreFileGroup, StoreFile,
  StoreRateResponse, StoreUploadResponse
} from '../model/StoreModel';
import { SDivider, CARD_RADIUS, PAD_H } from './SettingsControls';
import { ImmersiveLightWrapper } from '../common/ImmersiveLightWrapper';
import { gAbilityContext } from '../entryability/EntryAbility';

// ========== StoreCard ==========

@ComponentV2
export struct StoreCard {
  @Param app: StoreApp = {
    appid: '', name: '', vendor: '', size: 0,
    has_icon: false, rating: 0, rating_count: 0, resolutions: []
  };
  @Param serverUrl: string = '';
  @Event onCardClick: () => void = () => {};

  build() {
    Column() {
      // Icon
      if (this.app.has_icon && this.serverUrl.length > 0) {
        Image(StoreService.iconUrl(this.app.appid))
          .width(52)
          .height(52)
          .borderRadius(14)
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.Medium)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.square_grid_2x2'))
            .fontSize(28)
            .fontColor([$r('app.color.settings_desc_color')])
        }
        .width(52)
        .height(52)
        .borderRadius(14)
        .backgroundColor($r('app.color.settings_card_bg'))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      // Name
      Text(this.app.name)
        .fontSize(13)
        .fontColor($r('app.color.settings_label_color'))
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 8 })
        .width('100%')
        .textAlign(TextAlign.Center)
      // Vendor
      if (this.app.vendor.length > 0) {
        Text(this.app.vendor)
          .fontSize(11)
          .fontColor($r('app.color.settings_desc_color'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      // Rating + size
      Row() {
        if (this.app.rating > 0) {
          Row() {
            SymbolGlyph($r('sys.symbol.star_fill'))
              .fontSize(11)
              .fontColor([$r('app.color.accent_color')])
            Text(`${this.app.rating.toFixed(1)}`)
              .fontSize(10)
              .fontColor($r('app.color.accent_color'))
              .margin({ left: 2 })
          }
        }
        if (this.app.size > 0) {
          Text(`${(this.app.size / 1024).toFixed(0)}K`)
            .fontSize(10)
            .fontColor($r('app.color.settings_desc_color'))
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        }
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 10, bottom: 10 })
    .alignItems(HorizontalAlign.Center)
    .borderRadius(14)
    .backgroundColor($r('app.color.settings_card_bg'))
    .onClick(() => this.onCardClick())
  }
}

// ========== StoreSearch ==========

@ComponentV2
export struct StoreSearch {
  @Local query: string = '';
  @Local vendorFilter: string = '';
  @Local resFilter: string = '';
  @Param vendors: string[] = [];
  @Event onSearch: (query: string, vendor: string, res: string) => void = () => {};
  @Event onUpload: () => void = () => {};

  private static readonly RES_OPTIONS: string[] = ['', '240x320', '240x400', '320x480', '480x800'];

  build() {
    Column() {
      Search({ value: this.query, placeholder: $r('app.string.store_search_hint') })
        .width('100%')
        .height(36)
        .searchButton($r('app.string.store_search'))
        .onSubmit((value: string) => {
          this.query = value;
          this.onSearch(this.query, this.vendorFilter, this.resFilter);
        })
        .onChange((value: string) => {
          this.query = value;
        })
      // Filter row: vendor + resolution + upload
      Row({ space: 6 }) {
        // Vendor filter with clear
        if (this.vendors.length > 0) {
          Row() {
            Select(
              ['__all__'].concat(this.vendors).map((v: string): SelectOption => ({
                value: v === '__all__' ? $r('app.string.store_vendor_all') : v
              }))
            )
              .selected(this.vendorFilter.length === 0 ? 0 : -1)
              .value(this.vendorFilter.length > 0 ? this.vendorFilter : $r('app.string.store_vendor_all'))
              .font({ size: 11 })
              .onSelect((index: number) => {
                this.vendorFilter = index === 0 ? '' : this.vendors[index - 1];
                this.onSearch(this.query, this.vendorFilter, this.resFilter);
              })
              .layoutWeight(1)
            if (this.vendorFilter.length > 0) {
              SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                .fontSize(18)
                .fontColor([$r('app.color.settings_desc_color')])
                .margin({ left: 2 })
                .onClick(() => {
                  this.vendorFilter = '';
                  this.onSearch(this.query, '', this.resFilter);
                })
            }
          }
          .layoutWeight(1)
        }
        // Resolution filter with clear
        Row() {
          Select([
            { value: $r('app.string.store_res_all') } as SelectOption,
            { value: '240x320' } as SelectOption,
            { value: '240x400' } as SelectOption,
            { value: '320x480' } as SelectOption,
            { value: '480x800' } as SelectOption,
          ])
            .selected(this.resFilter.length === 0 ? 0 : -1)
            .value(this.resFilter.length > 0 ? this.resFilter : $r('app.string.store_res_all'))
            .font({ size: 11 })
            .onSelect((index: number) => {
              this.resFilter = index === 0 ? '' : StoreSearch.RES_OPTIONS[index];
              this.onSearch(this.query, this.vendorFilter, this.resFilter);
            })
            .layoutWeight(1)
          if (this.resFilter.length > 0) {
            SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
              .fontSize(18)
              .fontColor([$r('app.color.settings_desc_color')])
              .margin({ left: 2 })
              .onClick(() => {
                this.resFilter = '';
                this.onSearch(this.query, this.vendorFilter, '');
              })
          }
        }
        .layoutWeight(1)
        // Upload button
        Button() {
          SymbolGlyph($r('sys.symbol.upload'))
            .fontSize(16)
            .fontColor([$r('app.color.btn_text_on_accent')])
        }
        .height(30)
        .width(30)
        .padding(0)
        .backgroundColor($r('app.color.accent_color'))
        .borderRadius(8)
        .onClick(() => { this.onUpload(); })
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
  }
}

// ========== StoreDetailDialog ==========

@ComponentV2
export struct StoreDetailDialog {
  @Param appid: string = '';
  @Event onClose: () => void = () => {};
  @Local detail: StoreAppDetail | null = null;
  @Local ratingScore: string = '';
  @Local downloading: boolean = false;
  @Local downloadProgress: number = 0;
  @Local hasStatusMsg: boolean = false;
  @Local statusMsg: ResourceStr = '';

  aboutToAppear(): void {
    this.loadDetail();
  }

  private async loadDetail(): Promise<void> {
    this.detail = await StoreService.appDetail(this.appid);
  }

  build() {
    Column() {
      if (this.detail === null) {
        Column() {
          LoadingProgress().width(32).height(32).color($r('app.color.accent_color'))
        }
        .width('100%')
        .height(120)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        // Header: icon + name + vendor
        Row() {
          if (this.detail.has_icon) {
            Image(StoreService.iconUrl(this.detail.appid))
              .width(48).height(48).borderRadius(12).objectFit(ImageFit.Cover)
          } else {
            SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(48).fontColor([$r('app.color.settings_desc_color')])
          }
          Column() {
            Text(this.detail.name).fontSize(16).fontColor($r('app.color.settings_label_color')).fontWeight(FontWeight.Medium)
            Text(this.detail.vendor).fontSize(13).fontColor($r('app.color.settings_desc_color')).margin({ top: 2 })
            if (this.detail.rating > 0) {
              Row() {
                SymbolGlyph($r('sys.symbol.star_fill')).fontSize(14).fontColor([$r('app.color.accent_color')])
                Text(`${this.detail.rating.toFixed(1)} (${this.detail.rating_count})`).fontSize(12).fontColor($r('app.color.accent_color')).margin({ left: 2 })
              }.margin({ top: 2 })
            }
          }.layoutWeight(1).margin({ left: 12 }).alignItems(HorizontalAlign.Start)
        }.width('100%').padding(12)

        // Description
        if (this.detail.desc.length > 0) {
          Text(this.detail.desc)
            .fontSize(13).fontColor($r('app.color.settings_desc_color')).lineHeight(20)
            .width('100%').padding({ left: 12, right: 12, top: 4, bottom: 8 })
        }

        // Download buttons per resolution
        ForEach(this.detail.files, (group: StoreFileGroup) => {
          Row() {
            Text(group.resolution).fontSize(14).fontColor($r('app.color.settings_label_color')).layoutWeight(1)
            Button($r('app.string.store_detail_download'))
              .height(28).fontSize(12).fontColor($r('app.color.btn_text_on_accent'))
              .backgroundColor($r('app.color.accent_color')).borderRadius(8)
              .enabled(!this.downloading)
              .onClick(() => { this.doDownload(group.resolution); })
          }
          .width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
        }, (group: StoreFileGroup) => group.resolution)

        // Download progress
        if (this.downloading) {
          Row() {
            Progress({ value: this.downloadProgress * 100, total: 100, type: ProgressType.Linear })
              .width('60%').color($r('app.color.accent_color'))
            Text($r('app.string.store_download_progress')).fontSize(12).fontColor($r('app.color.settings_desc_color')).margin({ left: 8 })
          }.width('100%').padding({ left: 12, right: 12, top: 8 })
        }
        if (this.hasStatusMsg) {
          Text(this.statusMsg).fontSize(12).fontColor($r('app.color.accent_color')).padding({ left: 12, right: 12, top: 4 })
        }

        // Rating section
        SDivider()
        Row() {
          Text($r('app.string.store_rating_label')).fontSize(14).fontColor($r('app.color.settings_label_color')).layoutWeight(1)
          TextInput({ text: this.ratingScore, placeholder: '1-10' })
            .type(InputType.Number).width(60).height(32).fontSize(14)
            .onChange((v: string) => { this.ratingScore = v; })
          Button($r('app.string.store_rating_submit'))
            .height(28).fontSize(12).fontColor($r('app.color.btn_text_on_accent'))
            .backgroundColor($r('app.color.accent_color')).borderRadius(8).margin({ left: 8 })
            .onClick(() => { this.doRate(); })
        }
        .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }

      // Close button
      Button($r('app.string.btn_cancel'))
        .width('100%').height(36).fontSize(14)
        .backgroundColor($r('app.color.settings_card_bg')).fontColor($r('app.color.settings_label_color'))
        .margin({ top: 8 })
        .onClick(() => this.onClose())
    }
    .width('90%')
    .backgroundColor($r('app.color.settings_dialog_bg'))
    .borderRadius(16)
    .padding(12)
  }

  private async doDownload(resolution: string): Promise<void> {
    this.downloading = true;
    this.downloadProgress = 0;
    this.hasStatusMsg = false;
    try {
      await StoreService.downloadMrp(this.detail!.appid, resolution, undefined, (progress: number) => {
        this.downloadProgress = progress;
      });
      this.statusMsg = $r('app.string.store_download_success');
      this.hasStatusMsg = true;
    } catch (_e) {
      this.statusMsg = $r('app.string.store_download_failed');
      this.hasStatusMsg = true;
    }
    this.downloading = false;
  }

  private async doRate(): Promise<void> {
    const score = parseFloat(this.ratingScore);
    if (isNaN(score) || score < 1 || score > 10) return;
    const result: StoreRateResponse | null = await StoreService.addRating(this.detail!.appid, score);
    if (result !== null) {
      this.statusMsg = $r('app.string.store_rating_success');
      this.hasStatusMsg = true;
      // Refresh detail
      this.detail = await StoreService.appDetail(this.detail!.appid);
    }
  }
}

export interface StoreDetailDialogParams {
  appid: string;
  onClose: () => void;
}

@Builder
export function StoreDetailDialogBuilder($$: StoreDetailDialogParams) {
  StoreDetailDialog({
    appid: $$.appid,
    onClose: () => { $$.onClose(); }
  })
}

// ========== StoreUploadDialog ==========

@ComponentV2
export struct StoreUploadDialog {
  @Event onClose: () => void = () => {};
  @Event onUploaded: () => void = () => {};
  @Local filePath: string = '';
  @Local resWidth: string = '240';
  @Local resHeight: string = '320';
  @Local uploading: boolean = false;
  @Local uploadProgress: number = 0;
  @Local hasStatusMsg: boolean = false;
  @Local statusMsg: ResourceStr = '';
  @Local localMrpFiles: string[] = [];

  aboutToAppear(): void {
    this.loadLocalMrpFiles();
  }

  private loadLocalMrpFiles(): void {
    const ctx = gAbilityContext;
    if (!ctx) return;
    try {
      const mythroadDir = `${ctx.filesDir}/mythroad`;
      if (fs.accessSync(mythroadDir)) {
        const files = fs.listFileSync(mythroadDir);
        this.localMrpFiles = files.filter((f: string) => f.endsWith('.mrp'));
      }
    } catch (_e) {}
  }

  build() {
    Column() {
      Text($r('app.string.store_upload_title'))
        .fontSize(16).fontColor($r('app.color.settings_label_color')).fontWeight(FontWeight.Medium)
        .width('100%').padding({ bottom: 12 })

      // File selection
      Row() {
        Text($r('app.string.store_upload_select'))
          .fontSize(14).fontColor($r('app.color.settings_label_color')).layoutWeight(1)
        if (this.localMrpFiles.length > 0) {
          Select(this.localMrpFiles.map((f: string): SelectOption => ({ value: f })))
            .selected(0)
            .font({ size: 12 })
            .onSelect((index: number) => {
              this.filePath = `${gAbilityContext!.filesDir}/mythroad/${this.localMrpFiles[index]}`;
            })
            .width('60%')
        }
      }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })

      // Width & Height
      Row() {
        Text($r('app.string.store_upload_width'))
          .fontSize(14).fontColor($r('app.color.settings_label_color')).width(40)
        TextInput({ text: this.resWidth })
          .type(InputType.Number).width(60).height(32).fontSize(14)
          .onChange((v: string) => { this.resWidth = v; })
        Text($r('app.string.store_upload_height'))
          .fontSize(14).fontColor($r('app.color.settings_label_color')).width(40).margin({ left: 12 })
        TextInput({ text: this.resHeight })
          .type(InputType.Number).width(60).height(32).fontSize(14)
          .onChange((v: string) => { this.resHeight = v; })
      }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })

      // Upload progress
      if (this.uploading) {
        Row() {
          Progress({ value: this.uploadProgress * 100, total: 100, type: ProgressType.Linear })
            .width('60%').color($r('app.color.accent_color'))
          Text($r('app.string.store_upload_progress')).fontSize(12).fontColor($r('app.color.settings_desc_color')).margin({ left: 8 })
        }.width('100%').padding({ left: 12, right: 12, top: 8 })
      }
      if (this.hasStatusMsg) {
        Text(this.statusMsg).fontSize(12).fontColor($r('app.color.accent_color')).padding({ left: 12, top: 4 })
      }

      // Submit
      Row() {
        Button($r('app.string.store_upload_submit'))
          .height(36).fontSize(14).fontColor($r('app.color.btn_text_on_accent'))
          .backgroundColor($r('app.color.accent_color')).borderRadius(8)
          .enabled(!this.uploading && this.filePath.length > 0)
          .onClick(() => { this.doUpload(); })
        Button($r('app.string.btn_cancel'))
          .height(36).fontSize(14).fontColor($r('app.color.settings_label_color'))
          .backgroundColor($r('app.color.settings_card_bg')).borderRadius(8).margin({ left: 12 })
          .onClick(() => this.onClose())
      }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 12 })
    }
    .width('90%')
    .backgroundColor($r('app.color.settings_dialog_bg'))
    .borderRadius(16)
    .padding(12)
  }

  private async doUpload(): Promise<void> {
    const w = parseInt(this.resWidth, 10);
    const h = parseInt(this.resHeight, 10);
    if (isNaN(w) || isNaN(h) || w <= 0 || h <= 0) return;
    this.uploading = true;
    this.uploadProgress = 0;
    this.hasStatusMsg = false;
    try {
      const result: StoreUploadResponse | null = await StoreService.uploadMrp(this.filePath, w, h, (progress: number) => {
        this.uploadProgress = progress;
      });
      if (result !== null) {
        this.statusMsg = $r('app.string.store_upload_success');
        this.hasStatusMsg = true;
        this.onUploaded();
      } else {
        this.statusMsg = $r('app.string.store_upload_invalid');
        this.hasStatusMsg = true;
      }
    } catch (_e) {
      this.statusMsg = $r('app.string.store_upload_failed');
      this.hasStatusMsg = true;
    }
    this.uploading = false;
  }
}

export interface StoreUploadDialogParams {
  onUploaded: () => void;
  onClose: () => void;
}

@Builder
export function StoreUploadDialogBuilder($$: StoreUploadDialogParams) {
  StoreUploadDialog({
    onUploaded: () => { $$.onUploaded(); },
    onClose: () => { $$.onClose(); }
  })
}
