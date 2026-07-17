import { AppStorageV2, ComponentContent } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { AvoidData } from '../common/AvoidData';
import { HapticManager, HapticState, HapticStrength } from '../common/HapticManager';
import { VmrpEngineTs } from '../vmrp/VmrpEngine';
import { VmrpAssets } from '../vmrp/VmrpAssets';

const PREF_NAME = 'vmrp_settings';
const KEY_MEMORY = 'memory_mb';
const KEY_SENSITIVITY = 'motion_sensitivity';
const KEY_SHAKE_INTENSITY = 'shake_intensity';
const KEY_DISPLAY_FILTER = 'display_filter';
const KEY_SCREEN_EFFECT = 'screen_effect';
const KEY_SCREEN_EFFECT_STRENGTH = 'screen_effect_strength';
const KEY_BRIGHTNESS = 'brightness';
const KEY_CONTRAST = 'contrast';
const KEY_SATURATION = 'saturation';
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
const SHAKE_INTENSITY_OPTIONS: SelectOption[] = [
  { value: '轻柔' }, { value: '适中' }, { value: '强烈' }
];
const SHAKE_INTENSITY_VALUES: number[] = [0, 1, 2];
const DISPLAY_FILTER_OPTIONS: SelectOption[] = [
  { value: '原汁原味' }, { value: '柔和平滑' }, { value: '边缘抗锯齿' }, { value: '高级抗锯齿' }
];
const DISPLAY_FILTER_VALUES: number[] = [0, 1, 2, 3];
const SCREEN_EFFECT_OPTIONS: SelectOption[] = [
  { value: '关闭' }, { value: 'CRT 扫描线' }, { value: 'LCD 网格' }
];
const SCREEN_EFFECT_VALUES: number[] = [0, 1, 2];
const SCREEN_EFFECT_STRENGTH_DEFAULT: number = 0.5;
const BRIGHTNESS_DEFAULT: number = 0.0;
const CONTRAST_DEFAULT: number = 1.0;
const SATURATION_DEFAULT: number = 1.0;

@ComponentV2
export struct SettingsPage {
  @Local memoryMb: number = 1;
  @Local selectedIndex: number = 0;
  @Local hapticEnabled: boolean = true;
  @Local strengthIndex: number = 1;
  @Local shakeIntensityIndex: number = 1;
  @Local sensitivity: number = SENSITIVITY_DEFAULT;
  @Local displayFilterIndex: number = 0;
  @Local screenEffectIndex: number = 0;
  @Local screenEffectStrength: number = SCREEN_EFFECT_STRENGTH_DEFAULT;
  @Local brightnessVal: number = BRIGHTNESS_DEFAULT;
  @Local contrastVal: number = CONTRAST_DEFAULT;
  @Local saturationVal: number = SATURATION_DEFAULT;
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
  private hapticState: HapticState = HapticManager.getState();
  private navPathStack: NavPathStack | null = null;
  private engine: VmrpEngineTs = new VmrpEngineTs();

  aboutToAppear(): void {
    this.hapticEnabled = this.hapticState.enabled;
    this.strengthIndex = STRENGTH_VALUES.indexOf(this.hapticState.strength);
    if (this.strengthIndex < 0) this.strengthIndex = 1;
    this.loadPrefsSync();
  }

  loadPrefsSync(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) return;
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      this.memoryMb = pref.getSync(KEY_MEMORY, 1) as number;
      this.selectedIndex = MEMORY_VALUES.indexOf(this.memoryMb);
      if (this.selectedIndex < 0) this.selectedIndex = 0;
      this.sensitivity = pref.getSync(KEY_SENSITIVITY, SENSITIVITY_DEFAULT) as number;
      const shakeIntensity = pref.getSync(KEY_SHAKE_INTENSITY, 1) as number;
      this.shakeIntensityIndex = SHAKE_INTENSITY_VALUES.indexOf(shakeIntensity);
      if (this.shakeIntensityIndex < 0) this.shakeIntensityIndex = 1;
      const filterVal = pref.getSync(KEY_DISPLAY_FILTER, 0) as number;
      this.displayFilterIndex = DISPLAY_FILTER_VALUES.indexOf(filterVal);
      if (this.displayFilterIndex < 0) this.displayFilterIndex = 0;
      this.screenEffectIndex = SCREEN_EFFECT_VALUES.indexOf(pref.getSync(KEY_SCREEN_EFFECT, 0) as number);
      if (this.screenEffectIndex < 0) this.screenEffectIndex = 0;
      this.screenEffectStrength = pref.getSync(KEY_SCREEN_EFFECT_STRENGTH, SCREEN_EFFECT_STRENGTH_DEFAULT) as number;
      this.brightnessVal = pref.getSync(KEY_BRIGHTNESS, BRIGHTNESS_DEFAULT) as number;
      this.contrastVal = pref.getSync(KEY_CONTRAST, CONTRAST_DEFAULT) as number;
      this.saturationVal = pref.getSync(KEY_SATURATION, SATURATION_DEFAULT) as number;
    } catch (_e) {
    }
  }

  getPref(): preferences.Preferences | null {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) return null;
      return preferences.getPreferencesSync(ctx, { name: PREF_NAME });
    } catch (_e) {
      return null;
    }
  }

  applyDisplayFilter(): void {
    this.engine.setDisplayFilter(
      DISPLAY_FILTER_VALUES[this.displayFilterIndex],
      SCREEN_EFFECT_VALUES[this.screenEffectIndex],
      this.screenEffectStrength,
      this.brightnessVal,
      this.contrastVal,
      this.saturationVal
    );
  }

  saveDisplayFilter(): void {
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_DISPLAY_FILTER, DISPLAY_FILTER_VALUES[this.displayFilterIndex]);
    pref.putSync(KEY_SCREEN_EFFECT, SCREEN_EFFECT_VALUES[this.screenEffectIndex]);
    pref.putSync(KEY_SCREEN_EFFECT_STRENGTH, this.screenEffectStrength);
    pref.putSync(KEY_BRIGHTNESS, this.brightnessVal);
    pref.putSync(KEY_CONTRAST, this.contrastVal);
    pref.putSync(KEY_SATURATION, this.saturationVal);
    pref.flush();
    this.applyDisplayFilter();
  }

  saveMemory(mb: number): void {
    this.memoryMb = mb;
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_MEMORY, mb);
    pref.flush();
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

  saveSensitivity(val: number): void {
    this.sensitivity = val;
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_SENSITIVITY, val);
    pref.flush();
  }

  saveShakeIntensity(index: number): void {
    this.shakeIntensityIndex = index;
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_SHAKE_INTENSITY, SHAKE_INTENSITY_VALUES[index]);
    pref.flush();
  }

  resetDefaults(): void {
    this.selectedIndex = 0;
    this.memoryMb = 1;
    this.hapticEnabled = true;
    this.strengthIndex = 1;
    this.shakeIntensityIndex = 1;
    this.sensitivity = SENSITIVITY_DEFAULT;
    this.displayFilterIndex = 0;
    this.screenEffectIndex = 0;
    this.screenEffectStrength = SCREEN_EFFECT_STRENGTH_DEFAULT;
    this.brightnessVal = BRIGHTNESS_DEFAULT;
    this.contrastVal = CONTRAST_DEFAULT;
    this.saturationVal = SATURATION_DEFAULT;
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_MEMORY, 1);
    pref.putSync(KEY_SENSITIVITY, SENSITIVITY_DEFAULT);
    pref.putSync(KEY_SHAKE_INTENSITY, 1);
    pref.putSync(KEY_DISPLAY_FILTER, 0);
    pref.putSync(KEY_SCREEN_EFFECT, 0);
    pref.putSync(KEY_SCREEN_EFFECT_STRENGTH, SCREEN_EFFECT_STRENGTH_DEFAULT);
    pref.putSync(KEY_BRIGHTNESS, BRIGHTNESS_DEFAULT);
    pref.putSync(KEY_CONTRAST, CONTRAST_DEFAULT);
    pref.putSync(KEY_SATURATION, SATURATION_DEFAULT);
    pref.flush();
    this.applyDisplayFilter();
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      HapticManager.saveEnabledPref(ctx, true);
      HapticManager.saveStrengthPref(ctx, HapticStrength.MEDIUM);
    }
  }

  // 清空游戏文件二次确认。删除 mythroad 工作目录（含游戏、缓存、导入的 mrp），
  // 基础资源下次启动从 rawfile 重新解压。需停止引擎后再清空，避免运行时写冲突。
  confirmClearFiles(): void {
    this.getUIContext().showAlertDialog({
      title: '清空游戏文件',
      message: '将删除所有游戏、存档与缓存（含导入的 MRP），基础资源会在下次启动时自动恢复。此操作不可撤销，确定继续吗？',
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#E94560',
        action: () => {
          // 先停引擎，避免运行中删除文件导致崩溃。
          try { this.engine.stop(); } catch (e) {}
          const ctx = this.getUIContext().getHostContext();
          if (!ctx) return;
          const ok = VmrpAssets.clearWorkDir(ctx);
          this.getUIContext().getPromptAction().showToast({
            message: ok ? '已清空，重启应用后生效' : '清空失败',
            duration: 2500
          });
        }
      }
    });
  }

  // 备份沙箱数据到 zip。先弹文件名输入框，再走 picker 选保存位置。
  async doBackup(): Promise<void> {
    const uiCtx = this.getUIContext();
    const ctx = uiCtx.getHostContext();
    if (!ctx) return;
    // 默认文件名：vmrp_back_yyyyMMddHHmmss
    const now = new Date();
    const p = (n: number) => n.toString().padStart(2, '0');
    const defaultName = `vmrp_backup_${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
    // 弹出文件名输入对话框
    const prompt = uiCtx.getPromptAction();
    const params: BackupNameDialogParams = {
      fileName: defaultName,
      onConfirm: async (name: string) => {
        prompt.closeCustomDialog(contentNode);
        await this.executeBackup(ctx, name);
      },
      onCancel: () => { prompt.closeCustomDialog(contentNode); }
    };
    const contentNode = new ComponentContent(uiCtx, wrapBuilder(BackupNameDialogBuilder), params);
    prompt.openCustomDialog(contentNode, {
      alignment: DialogAlignment.Center,
      autoCancel: true
    });
  }

  private async executeBackup(ctx: common.Context, fileName: string): Promise<void> {
    try {
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [fileName.toLowerCase().endsWith('.zip') ? fileName : `${fileName}.zip`];
      opt.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.save(opt);
      if (!uris || uris.length === 0) return; // 用户取消
      const destUri = uris[0];
      this.getUIContext().getPromptAction().showToast({ message: '正在备份...' });
      const ok = await VmrpAssets.backupToZip(ctx, destUri, fileName);
      this.getUIContext().getPromptAction().showToast({
        message: ok ? '备份成功' : '备份失败',
        duration: 2500
      });
    } catch (e) {
      console.error(`doBackup failed: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '备份失败', duration: 2500 });
    }
  }

  // 恢复数据二次确认。从 zip 解压覆盖到沙箱，会覆盖当前数据。
  confirmRestore(): void {
    this.getUIContext().showAlertDialog({
      title: '恢复数据',
      message: '将从备份文件恢复数据，当前的游戏、存档和缓存将被覆盖。确定继续吗？',
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '选择备份文件',
        fontColor: '#E94560',
        action: async () => {
          try {
            const opt = new picker.DocumentSelectOptions();
            opt.maxSelectNumber = 1;
            opt.fileSuffixFilters = ['.zip'];
            const docPicker = new picker.DocumentViewPicker();
            const uris = await docPicker.select(opt);
            if (!uris || uris.length === 0) return; // 用户取消
            const srcUri = uris[0];
            // 停引擎，避免恢复时文件冲突。
            try { this.engine.stop(); } catch (e) {}
            const ctx = this.getUIContext().getHostContext();
            if (!ctx) return;
            this.getUIContext().getPromptAction().showToast({ message: '正在恢复...' });
            const ok = await VmrpAssets.restoreFromZip(ctx, srcUri);
            this.getUIContext().getPromptAction().showToast({
              message: ok ? '恢复成功，重启应用后生效' : '恢复失败',
              duration: 2500
            });
          } catch (e) {
            console.error(`doRestore failed: ${JSON.stringify(e)}`);
            this.getUIContext().getPromptAction().showToast({ message: '恢复失败', duration: 2500 });
          }
        }
      }
    });
  }

  // 批量导入 MRP 游戏文件到 mythroad 目录。
  async doImportMrp(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) return;
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 100;
      opt.fileSuffixFilters = ['.mrp'];
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.select(opt);
      if (!uris || uris.length === 0) return; // 用户取消
      this.getUIContext().getPromptAction().showToast({ message: '正在导入...' });
      const count = await VmrpAssets.importMrpBatch(ctx, uris);
      this.getUIContext().getPromptAction().showToast({
        message: count > 0 ? `已导入 ${count} 个游戏` : '导入失败',
        duration: 2500
      });
    } catch (e) {
      console.error(`doImportMrp failed: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '导入失败', duration: 2500 });
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

          ListItemGroup({ header: this.sectionHeader('画面') }) {
            ListItem() {
              Row() {
                Text('缩放滤镜')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)

                this.selectStyle(DISPLAY_FILTER_OPTIONS, this.displayFilterIndex,
                  DISPLAY_FILTER_OPTIONS[this.displayFilterIndex].value as string,
                  (index: number) => {
                    this.displayFilterIndex = index;
                    this.saveDisplayFilter();
                  })
              }
              .width('100%')
              .height(56)
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16 })
            }

            ListItem() {
              Text('原汁原味保留像素锯齿，柔和平滑全图模糊，边缘/高级抗锯齿只平滑斜线和曲线。即时生效。')
                .fontSize(12)
                .fontColor('#666688')
                .width('100%')
                .padding({ left: 16, right: 16, top: 0, bottom: 8 })
            }

            ListItem() {
              Row() {
                Text('屏幕效果')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)

                this.selectStyle(SCREEN_EFFECT_OPTIONS, this.screenEffectIndex,
                  SCREEN_EFFECT_OPTIONS[this.screenEffectIndex].value as string,
                  (index: number) => {
                    this.screenEffectIndex = index;
                    this.saveDisplayFilter();
                  })
              }
              .width('100%')
              .height(56)
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16 })
            }

            ListItem() {
              Text('CRT扫描线模拟老式显像管电视，LCD网格模拟老式手机屏幕竖条纹。')
                .fontSize(12)
                .fontColor('#666688')
                .width('100%')
                .padding({ left: 16, right: 16, top: 0, bottom: 8 })
            }

            ListItem() {
              Row() {
                Text('效果强度')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)
                Text(`${this.screenEffectStrength.toFixed(2)}`)
                  .fontSize(14)
                  .fontColor('#E94560')
                  .width(50)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 0 })
            }
            ListItem() {
              Slider({ value: this.screenEffectStrength, min: 0.0, max: 1.0, step: 0.05 })
                .width('100%')
                .trackColor('#2A2A4E')
                .selectedColor('#E94560')
                .blockColor('#FFFFFF')
                .blockBorderColor('#E94560')
                .blockBorderWidth(2)
                .blockSize({ width: 20, height: 20 })
                .padding({ left: 16, right: 16 })
                .onChange((value: number) => {
                  this.screenEffectStrength = value;
                  this.saveDisplayFilter();
                })
            }

            // 亮度
            ListItem() {
              Row() {
                Text('亮度')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)
                Text(`${this.brightnessVal.toFixed(2)}`)
                  .fontSize(14)
                  .fontColor('#E94560')
                  .width(50)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 0 })
            }
            ListItem() {
              Slider({ value: this.brightnessVal, min: -0.3, max: 0.3, step: 0.02 })
                .width('100%')
                .trackColor('#2A2A4E')
                .selectedColor('#E94560')
                .blockColor('#FFFFFF')
                .blockBorderColor('#E94560')
                .blockBorderWidth(2)
                .blockSize({ width: 20, height: 20 })
                .padding({ left: 16, right: 16 })
                .onChange((value: number) => {
                  this.brightnessVal = value;
                  this.saveDisplayFilter();
                })
            }

            // 对比度
            ListItem() {
              Row() {
                Text('对比度')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)
                Text(`${this.contrastVal.toFixed(2)}`)
                  .fontSize(14)
                  .fontColor('#E94560')
                  .width(50)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 0 })
            }
            ListItem() {
              Slider({ value: this.contrastVal, min: 0.5, max: 2.0, step: 0.05 })
                .width('100%')
                .trackColor('#2A2A4E')
                .selectedColor('#E94560')
                .blockColor('#FFFFFF')
                .blockBorderColor('#E94560')
                .blockBorderWidth(2)
                .blockSize({ width: 20, height: 20 })
                .padding({ left: 16, right: 16 })
                .onChange((value: number) => {
                  this.contrastVal = value;
                  this.saveDisplayFilter();
                })
            }

            // 饱和度
            ListItem() {
              Row() {
                Text('饱和度')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)
                Text(`${this.saturationVal.toFixed(2)}`)
                  .fontSize(14)
                  .fontColor('#E94560')
                  .width(50)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 0 })
            }
            ListItem() {
              Slider({ value: this.saturationVal, min: 0.0, max: 2.0, step: 0.05 })
                .width('100%')
                .trackColor('#2A2A4E')
                .selectedColor('#E94560')
                .blockColor('#FFFFFF')
                .blockBorderColor('#E94560')
                .blockBorderWidth(2)
                .blockSize({ width: 20, height: 20 })
                .padding({ left: 16, right: 16 })
                .onChange((value: number) => {
                  this.saturationVal = value;
                  this.saveDisplayFilter();
                })
            }

            ListItem() {
              Button('重置画面设置')
                .width('100%')
                .height(40)
                .fontSize(14)
                .fontColor('#E94560')
                .backgroundColor('#16213E')
                .borderRadius(8)
                .onClick(() => {
                  this.displayFilterIndex = 0;
                  this.screenEffectIndex = 0;
                  this.screenEffectStrength = SCREEN_EFFECT_STRENGTH_DEFAULT;
                  this.brightnessVal = BRIGHTNESS_DEFAULT;
                  this.contrastVal = CONTRAST_DEFAULT;
                  this.saturationVal = SATURATION_DEFAULT;
                  this.saveDisplayFilter();
                })
            }
            .padding({ left: 16, right: 16, top: 4, bottom: 12 })
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

          ListItemGroup({ header: this.sectionHeader('游戏震动') }) {
            ListItem() {
              Row() {
                Text('震动强度')
                  .fontSize(16)
                  .fontColor('#CCCCCC')
                  .layoutWeight(1)

                this.selectStyle(SHAKE_INTENSITY_OPTIONS, this.shakeIntensityIndex,
                  SHAKE_INTENSITY_OPTIONS[this.shakeIntensityIndex].value as string,
                  (index: number) => {
                    this.saveShakeIntensity(index);
                  })
              }
              .width('100%')
              .height(56)
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16 })
            }

            ListItem() {
              Text('调节游戏中 mr_startShake 触发的振动强度。轻柔=短振, 强烈=长振+闹钟模式。即时生效。')
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
                min: 0.2,
                max: 3.0,
                step: 0.1
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

          ListItemGroup({ header: this.sectionHeader('数据管理') }) {
            ListItem() {
              Column() {
                Button('备份数据')
                  .width('100%')
                  .height(44)
                  .fontSize(16)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#1A1A2E')
                  .borderRadius(12)
                  .onClick(() => {
                    this.doBackup();
                  })
                Text('将游戏、存档和缓存打包为 zip 保存到下载目录')
                  .fontSize(12)
                  .fontColor('#6666AA')
                  .margin({ top: 6 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .padding({ left: 16, right: 16, top: 10, bottom: 4 })

            ListItem() {
              Column() {
                Button('恢复数据')
                  .width('100%')
                  .height(44)
                  .fontSize(16)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#1A1A2E')
                  .borderRadius(12)
                  .onClick(() => {
                    this.confirmRestore();
                  })
                Text('从 zip 文件导入文件到内存卡(沙箱),同名覆盖')
                  .fontSize(12)
                  .fontColor('#6666AA')
                  .margin({ top: 6 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })

            ListItem() {
              Column() {
                Button('导入游戏')
                  .width('100%')
                  .height(44)
                  .fontSize(16)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#1A1A2E')
                  .borderRadius(12)
                  .onClick(() => {
                    this.doImportMrp();
                  })
                Text('批量导入 .mrp 游戏文件到内存卡')
                  .fontSize(12)
                  .fontColor('#6666AA')
                  .margin({ top: 6 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .padding({ left: 16, right: 16, top: 4, bottom: 10 })
          }
          .divider({ strokeWidth: 0.5, color: '#2A2A4E', startMargin: 16, endMargin: 16 })
          .backgroundColor('#1A1A2E')
          .borderRadius(16)

          ListItemGroup({ header: this.sectionHeader('') }) {
            ListItem() {
              Button('清空游戏文件')
                .width('100%')
                .height(48)
                .fontSize(16)
                .fontColor('#E94560')
                .backgroundColor('#1A1A2E')
                .borderRadius(12)
                .onClick(() => {
                  this.confirmClearFiles();
                })
            }
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })

            ListItem() {
              Button('恢复默认设置')
                .width('100%')
                .height(48)
                .fontSize(16)
                .fontColor('#E94560')
                .backgroundColor('#1A1A2E')
                .borderRadius(12)
                .onClick(() => {
                  this.resetDefaults();
                })
            }
            .padding({ left: 16, right: 16, top: 4, bottom: 8 })
          }
          .backgroundColor(Color.Transparent)
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

// === 备份文件名输入对话框 ===
interface BackupNameDialogParams {
  fileName: string;
  onConfirm: (name: string) => void;
  onCancel: () => void;
}

@Builder
function BackupNameDialogBuilder($$: BackupNameDialogParams) {
  Column() {
    Text('备份文件名')
      .fontSize(17)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Medium)
      .margin({ top: 20, bottom: 6 })
    Text('将保存为 zip 文件到下载目录，同名文件将被覆盖')
      .fontSize(12)
      .fontColor('#8888AA')
      .margin({ bottom: 14 })
    TextInput({ text: $$.fileName })
      .onChange((v: string) => { $$.fileName = v; })
      .width('85%')
      .height(44)
      .fontSize(15)
      .backgroundColor('#1A1A2E')
      .fontColor('#FFFFFF')
      .borderRadius(10)
    Row() {
      Button('取消')
        .width(100)
        .height(40)
        .backgroundColor('#333355')
        .fontColor('#CCCCCC')
        .onClick(() => { $$.onCancel(); })
      Button('备份')
        .width(100)
        .height(40)
        .backgroundColor('#E94560')
        .fontColor('#FFFFFF')
        .onClick(() => { $$.onConfirm($$.fileName); })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceEvenly)
    .margin({ top: 16, bottom: 20 })
  }
  .width('82%')
  .backgroundColor('#16213E')
  .borderRadius(16)
}
