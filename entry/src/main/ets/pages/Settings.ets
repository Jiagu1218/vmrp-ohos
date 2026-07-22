import { AppStorageV2, ComponentContent, LengthMetrics } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { HdsNavDestination, HdsNavDestinationAttribute, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { AvoidData } from '../common/AvoidData';
import { HapticManager, HapticState, HapticStrength } from '../common/HapticManager';
import { VmrpEngineTs } from '../vmrp/VmrpEngine';
import { VmrpAssets } from '../vmrp/VmrpAssets';
import { ImmersiveLightWrapper } from '../common/ImmersiveLightWrapper';
import { GlassPanel } from '../common/GlassPanel';

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
const KEY_SUBPIXEL_RENDER = 'subpixel_render';
const KEY_GAMMA_CORRECT = 'gamma_correct';
const KEY_DITHER = 'dither';
const KEY_SCREEN_W = 'screen_width';
const KEY_SCREEN_H = 'screen_height';
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
  { value: '原汁原味' }, { value: '柔和平滑' }, { value: '边缘抗锯齿' }, { value: '高级抗锯齿' }, { value: 'AI 超分' }
];
const DISPLAY_FILTER_VALUES: number[] = [0, 1, 2, 3, 4];
const SCREEN_EFFECT_OPTIONS: SelectOption[] = [
  { value: '关闭' }, { value: '完整 CRT' }, { value: 'LCD 网格' }, { value: '仅扫描线' }
];
const SCREEN_EFFECT_VALUES: number[] = [0, 1, 2, 3];
const SCREEN_EFFECT_STRENGTH_DEFAULT: number = 0.5;
const BRIGHTNESS_DEFAULT: number = 0.0;
const CONTRAST_DEFAULT: number = 1.0;
const SATURATION_DEFAULT: number = 1.0;
const SUBPIXEL_RENDER_DEFAULT: number = 0;
const GAMMA_CORRECT_DEFAULT: number = 1;
const DITHER_DEFAULT: number = 1;
const SCREEN_SIZE_OPTIONS: SelectOption[] = [
  { value: '176×220' }, { value: '240×320' }, { value: '240×400' },
  { value: '320×480' }, { value: '320×240' }, { value: '480×800' }
];
const SCREEN_SIZE_W: number[] = [176, 240, 240, 320, 320, 480];
const SCREEN_SIZE_H: number[] = [220, 320, 400, 480, 240, 800];
const SCREEN_SIZE_DEFAULT_INDEX: number = 1;
const KEY_SPEED_MULT = 'speed_multiplier';
const KEY_GAMEPAD_MAP = 'gamepad_mapping';
const SPEED_OPTIONS: SelectOption[] = [
  { value: '1x 正常' }, { value: '2x 加速' }, { value: '3x 高速' }, { value: '4x 极速' }
];
const SPEED_VALUES: number[] = [1, 2, 3, 4];
const GAMEPAD_MAP_OPTIONS: SelectOption[] = [
  { value: '经典' }, { value: '方向优先' }, { value: '数字键盘' }
];
const GAMEPAD_MAP_VALUES: number[] = [0, 1, 2];

const CARD_RADIUS = 20;
const ROW_H = 56;
const PAD_H = 20;
const SEC_TOP = 20;
const SEC_BOT = 6;

@ComponentV2
struct SectionHeader {
  @Param title: string = '';
  build() {
    Text(this.title)
      .fontSize(14)
      .fontColor($r('app.color.settings_desc_color'))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 4, top: SEC_TOP, bottom: SEC_BOT })
  }
}

@ComponentV2
struct SDivider {
  build() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor($r('app.color.settings_divider_color'))
      .margin({ left: PAD_H, right: 0 })
  }
}

@ComponentV2
struct SDesc {
  @Param text: string = '';
  build() {
    Text(this.text)
      .fontSize(12)
      .fontColor($r('app.color.settings_desc_color'))
      .width('100%')
      .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 12 })
  }
}

@ComponentV2
struct SRow {
  @BuilderParam content: () => void;
  @Param label: string = '';
  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor($r('app.color.settings_label_color'))
        .layoutWeight(1)
      this.content()
    }
    .width('100%')
    .height(ROW_H)
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAD_H, right: PAD_H })
  }
}

@ComponentV2
struct SSliderLabel {
  @Param label: string = '';
  @Param valueText: string = '';
  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor($r('app.color.settings_label_color'))
        .layoutWeight(1)
      Text(this.valueText)
        .fontSize(13)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Medium)
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(8)
        .backgroundColor($r('app.color.settings_slider_value_bg'))
    }
    .width('100%')
    .padding({ left: PAD_H, right: PAD_H, top: 12, bottom: 4 })
  }
}

@ComponentV2
struct SSlider {
  @Param value: number = 0;
  @Param min: number = 0;
  @Param max: number = 1;
  @Param step: number = 0.05;
  @Event onChange: (v: number) => void = (_v: number) => {};
  build() {
    Row() {
      Slider({ value: this.value, min: this.min, max: this.max, step: this.step, style: SliderStyle.InSet })
        .width('100%')
        .trackColor($r('app.color.settings_slider_track'))
        .selectedColor($r('app.color.accent_color'))
        .blockColor('#FFFFFF')
        .blockSize({ width: 20, height: 20 })
        .trackBorderRadius(10)
        .border({ width: 0 })
        .padding({ left: 0, right: 0 })
        .onChange((v: number) => { this.onChange(v); })
    }
    .padding({ left: PAD_H, right: PAD_H })
  }
}

@ComponentV2
struct SSelect {
  @Param opts: SelectOption[] = [];
  @Param selected: number = 0;
  @Param value: string = '';
  @Event onSelect: (index: number) => void = (_index: number) => {};
  build() {
    Select(this.opts)
      .selected(this.selected)
      .value(this.value)
      .font({ size: 14 })
      .fontColor($r('app.color.settings_label_color'))
      .selectedOptionFont({ size: 15, weight: FontWeight.Bold })
      .selectedOptionFontColor('#FFFFFF')
      .selectedOptionBgColor($r('app.color.accent_color'))
      .optionFont({ size: 14 })
      .optionFontColor($r('app.color.settings_desc_color'))
      .optionBgColor($r('app.color.settings_select_option_bg'))
      .menuBackgroundColor($r('app.color.settings_select_menu_bg'))
      .menuBackgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .backgroundColor($r('app.color.settings_select_bg'))
      .borderRadius(8)
      .onSelect((index: number) => { this.onSelect(index); })
  }
}

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
  @Local subpixelRender: number = SUBPIXEL_RENDER_DEFAULT;
  @Local gammaCorrect: number = GAMMA_CORRECT_DEFAULT;
  @Local ditherEnabled: number = DITHER_DEFAULT;
  @Local screenSizeIndex: number = SCREEN_SIZE_DEFAULT_INDEX;
  @Local speedMultIndex: number = 0;
  @Local gamepadMapIndex: number = 0;
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
  private hapticState: HapticState = HapticManager.getState();
  private navPathStack: NavPathStack | null = null;
  private engine: VmrpEngineTs = new VmrpEngineTs();
  private listScroller: Scroller = new Scroller();

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
      this.subpixelRender = pref.getSync(KEY_SUBPIXEL_RENDER, SUBPIXEL_RENDER_DEFAULT) as number;
      this.gammaCorrect = pref.getSync(KEY_GAMMA_CORRECT, GAMMA_CORRECT_DEFAULT) as number;
      this.ditherEnabled = pref.getSync(KEY_DITHER, DITHER_DEFAULT) as number;
      const sw = pref.getSync(KEY_SCREEN_W, 240) as number;
      const sh = pref.getSync(KEY_SCREEN_H, 320) as number;
      const screenIdx = SCREEN_SIZE_W.indexOf(sw);
      this.screenSizeIndex = (screenIdx >= 0 && SCREEN_SIZE_H[screenIdx] === sh) ? screenIdx : SCREEN_SIZE_DEFAULT_INDEX;
      const speedMult = pref.getSync(KEY_SPEED_MULT, 1) as number;
      this.speedMultIndex = SPEED_VALUES.indexOf(speedMult);
      if (this.speedMultIndex < 0) this.speedMultIndex = 0;
      const gamepadMap = pref.getSync(KEY_GAMEPAD_MAP, 0) as number;
      this.gamepadMapIndex = GAMEPAD_MAP_VALUES.indexOf(gamepadMap);
      if (this.gamepadMapIndex < 0) this.gamepadMapIndex = 0;
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
      this.saturationVal,
      this.subpixelRender,
      this.gammaCorrect,
      this.ditherEnabled
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
    pref.putSync(KEY_SUBPIXEL_RENDER, this.subpixelRender);
    pref.putSync(KEY_GAMMA_CORRECT, this.gammaCorrect);
    pref.putSync(KEY_DITHER, this.ditherEnabled);
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

  saveSpeedMult(index: number): void {
    this.speedMultIndex = index;
    const mult = SPEED_VALUES[index];
    this.engine.setSpeedMultiplier(mult);
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_SPEED_MULT, mult);
    pref.flush();
  }

  saveGamepadMap(index: number): void {
    this.gamepadMapIndex = index;
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_GAMEPAD_MAP, GAMEPAD_MAP_VALUES[index]);
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

  saveScreenSize(index: number): void {
    this.screenSizeIndex = index;
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_SCREEN_W, SCREEN_SIZE_W[index]);
    pref.putSync(KEY_SCREEN_H, SCREEN_SIZE_H[index]);
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
    this.subpixelRender = SUBPIXEL_RENDER_DEFAULT;
    this.gammaCorrect = GAMMA_CORRECT_DEFAULT;
    this.ditherEnabled = DITHER_DEFAULT;
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
    pref.putSync(KEY_SUBPIXEL_RENDER, SUBPIXEL_RENDER_DEFAULT);
    pref.putSync(KEY_GAMMA_CORRECT, GAMMA_CORRECT_DEFAULT);
    pref.putSync(KEY_DITHER, DITHER_DEFAULT);
    pref.putSync(KEY_SCREEN_W, 240);
    pref.putSync(KEY_SCREEN_H, 320);
    pref.flush();
    this.applyDisplayFilter();
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      HapticManager.saveEnabledPref(ctx, true);
      HapticManager.saveStrengthPref(ctx, HapticStrength.MEDIUM);
    }
  }

  confirmClearFiles(): void {
    this.getUIContext().showAlertDialog({
      title: '清空游戏文件',
      message: '将删除所有游戏、存档与缓存（含导入的 MRP），基础资源会在下次启动时自动恢复。此操作不可撤销，确定继续吗？',
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '清空',
        fontColor: '#D63B55',
        action: () => {
          try { this.engine.stop(); } catch (_e) {}
          const ctx = this.getUIContext().getHostContext();
          if (!ctx) return;
          const ok = VmrpAssets.clearWorkDir(ctx);
          this.getUIContext().getPromptAction().showToast({
            message: ok ? '已清空，重启应用后生效' : '清空失败', duration: 2500
          });
        }
      }
    });
  }

  async doBackup(): Promise<void> {
    const uiCtx = this.getUIContext();
    const ctx = uiCtx.getHostContext();
    if (!ctx) return;
    const now = new Date();
    const p = (n: number) => n.toString().padStart(2, '0');
    const defaultName = `vmrp_backup_${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
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
    prompt.openCustomDialog(contentNode, { alignment: DialogAlignment.Center, autoCancel: true });
  }

  private async executeBackup(ctx: common.Context, fileName: string): Promise<void> {
    try {
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [fileName.toLowerCase().endsWith('.zip') ? fileName : `${fileName}.zip`];
      opt.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.save(opt);
      if (!uris || uris.length === 0) return;
      const destUri = uris[0];
      this.getUIContext().getPromptAction().showToast({ message: '正在备份...' });
      const ok = await VmrpAssets.backupToZip(ctx, destUri, fileName);
      this.getUIContext().getPromptAction().showToast({ message: ok ? '备份成功' : '备份失败', duration: 2500 });
    } catch (e) {
      console.error(`doBackup failed: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '备份失败', duration: 2500 });
    }
  }

  confirmRestore(): void {
    this.getUIContext().showAlertDialog({
      title: '恢复数据',
      message: '将从备份文件恢复数据，当前的游戏、存档和缓存将被覆盖。确定继续吗？',
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '选择备份文件',
        fontColor: '#D63B55',
        action: async () => {
          try {
            const opt = new picker.DocumentSelectOptions();
            opt.maxSelectNumber = 1;
            opt.fileSuffixFilters = ['.zip'];
            const docPicker = new picker.DocumentViewPicker();
            const uris = await docPicker.select(opt);
            if (!uris || uris.length === 0) return;
            const srcUri = uris[0];
            try { this.engine.stop(); } catch (_e) {}
            const ctx = this.getUIContext().getHostContext();
            if (!ctx) return;
            this.getUIContext().getPromptAction().showToast({ message: '正在恢复...' });
            const ok = await VmrpAssets.restoreFromZip(ctx, srcUri);
            this.getUIContext().getPromptAction().showToast({
              message: ok ? '恢复成功，重启应用后生效' : '恢复失败', duration: 2500
            });
          } catch (e) {
            console.error(`doRestore failed: ${JSON.stringify(e)}`);
            this.getUIContext().getPromptAction().showToast({ message: '恢复失败', duration: 2500 });
          }
        }
      }
    });
  }

  async doImportMrp(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) return;
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 100;
      opt.fileSuffixFilters = ['.mrp'];
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.select(opt);
      if (!uris || uris.length === 0) return;
      this.getUIContext().getPromptAction().showToast({ message: '正在导入...' });
      const count = await VmrpAssets.importMrpBatch(ctx, uris);
      this.getUIContext().getPromptAction().showToast({
        message: count > 0 ? `已导入 ${count} 个游戏` : '导入失败', duration: 2500
      });
    } catch (e) {
      console.error(`doImportMrp failed: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '导入失败', duration: 2500 });
    }
  }

  build() {
    HdsNavDestination() {
      List({ space: 8, scroller: this.listScroller }) {

        // ── 模拟器 ──
        ListItem() {
          Column() {
            SectionHeader({ title: '模拟器' })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
               Column() {
                 SRow({ label: '屏幕分辨率' }) {
                   SSelect({
                     opts: SCREEN_SIZE_OPTIONS,
                     selected: this.screenSizeIndex,
                     value: SCREEN_SIZE_OPTIONS[this.screenSizeIndex].value as string,
                     onSelect: (index: number) => { this.saveScreenSize(index); }
                   })
                 }
                 SDesc({ text: '设置模拟器屏幕分辨率，需在下一次启动时生效。不同 MRP 应用可能需要匹配其原始设备的分辨率。' })
                 SDivider()
                 SRow({ label: '内存大小' }) {
                  SSelect({
                    opts: MEMORY_OPTIONS,
                    selected: this.selectedIndex,
                    value: `${this.memoryMb} MB`,
                    onSelect: (index: number) => {
                      this.selectedIndex = index;
                      this.saveMemory(MEMORY_VALUES[index]);
                    }
                  })
                }
                 SDesc({ text: '内存大小决定 MRP 可见的堆空间，需在下一次启动时生效。' })
                 SDivider()
                 SRow({ label: '模拟速度' }) {
                   SSelect({
                     opts: SPEED_OPTIONS,
                     selected: this.speedMultIndex,
                     value: SPEED_OPTIONS[this.speedMultIndex].value as string,
                     onSelect: (index: number) => {
                       this.saveSpeedMult(index);
                     }
                   })
                 }
                 SDesc({ text: '加快游戏运行速度，1x为正常速度，4x为极速。运行中也可在模拟器页面临时切换。' })
               }
            }
          }
        }
        .padding({ left: 16, right: 16 })

        // ── 画面 ──
        ListItem() {
          Column() {
            SectionHeader({ title: '画面' })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                SRow({ label: '缩放滤镜' }) {
                  SSelect({
                    opts: DISPLAY_FILTER_OPTIONS,
                    selected: this.displayFilterIndex,
                    value: DISPLAY_FILTER_OPTIONS[this.displayFilterIndex].value as string,
                    onSelect: (index: number) => {
                      this.displayFilterIndex = index;
                      this.saveDisplayFilter();
                    }
                  })
                }
                SDesc({ text: '原汁原味保留像素锯齿，柔和平滑全图模糊，边缘/高级抗锯齿只平滑斜线和曲线，AI超分使用 FSRCNNX 锐化上采样。即时生效。' })

                SDivider()
                SRow({ label: '屏幕效果' }) {
                  SSelect({
                    opts: SCREEN_EFFECT_OPTIONS,
                    selected: this.screenEffectIndex,
                    value: SCREEN_EFFECT_OPTIONS[this.screenEffectIndex].value as string,
                    onSelect: (index: number) => {
                      this.screenEffectIndex = index;
                      this.saveDisplayFilter();
                    }
                  })
                }
                SDesc({ text: '完整CRT模拟显像管电视（磷光余辉+荫罩+扫描线+桶形畸变），LCD网格模拟老式手机屏幕竖条纹，仅扫描线只加扫描线效果。' })

                SDivider()
                SSliderLabel({ label: '效果强度', valueText: `${this.screenEffectStrength.toFixed(2)}` })
                SSlider({
                  value: this.screenEffectStrength, min: 0.0, max: 1.0, step: 0.05,
                  onChange: (v: number) => { this.screenEffectStrength = v; this.saveDisplayFilter(); }
                })

                SDivider()
                SSliderLabel({ label: '亮度', valueText: `${this.brightnessVal.toFixed(2)}` })
                SSlider({
                  value: this.brightnessVal, min: -0.3, max: 0.3, step: 0.02,
                  onChange: (v: number) => { this.brightnessVal = v; this.saveDisplayFilter(); }
                })

                SDivider()
                SSliderLabel({ label: '对比度', valueText: `${this.contrastVal.toFixed(2)}` })
                SSlider({
                  value: this.contrastVal, min: 0.5, max: 2.0, step: 0.05,
                  onChange: (v: number) => { this.contrastVal = v; this.saveDisplayFilter(); }
                })

                SDivider()
                SSliderLabel({ label: '饱和度', valueText: `${this.saturationVal.toFixed(2)}` })
                SSlider({
                  value: this.saturationVal, min: 0.0, max: 2.0, step: 0.05,
                  onChange: (v: number) => { this.saturationVal = v; this.saveDisplayFilter(); }
                })

                SDivider()
                SRow({ label: '子像素渲染' }) {
                  Toggle({ type: ToggleType.Switch, isOn: this.subpixelRender === 1 })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .onChange((isOn: boolean) => { this.subpixelRender = isOn ? 1 : 0; this.saveDisplayFilter(); })
                }
                SDesc({ text: '利用 LCD 子像素 RGB 排列提升文字和边缘的清晰度，在高分辨率屏幕上效果明显。' })

                SDivider()
                SRow({ label: 'Gamma 校正' }) {
                  Toggle({ type: ToggleType.Switch, isOn: this.gammaCorrect === 1 })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .onChange((isOn: boolean) => { this.gammaCorrect = isOn ? 1 : 0; this.saveDisplayFilter(); })
                }
                SDesc({ text: '将 sRGB 伽马曲线应用于亮度/对比度/饱和度调整前，避免色彩偏移。建议保持开启。' })

                SDivider()
                SRow({ label: 'RGB565 抖动' }) {
                  Toggle({ type: ToggleType.Switch, isOn: this.ditherEnabled === 1 })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .onChange((isOn: boolean) => { this.ditherEnabled = isOn ? 1 : 0; this.saveDisplayFilter(); })
                }
                SDesc({ text: 'RGB565 转 RGBA 时施加 Bayer 抖动，减少色带过渡的阶梯感。建议保持开启。' })

                SDivider()
                Column() {
                  Button('重置画面设置')
                    .width('100%')
                    .height(40)
                    .fontSize(14)
                    .fontColor($r('app.color.accent_color'))
                    .backgroundColor(Color.Transparent)
                    .borderRadius(8)
                    .border({ width: 1, color: $r('app.color.settings_reset_btn_border') })
                    .onClick(() => {
                       this.displayFilterIndex = 0;
                       this.screenEffectIndex = 0;
                       this.screenEffectStrength = SCREEN_EFFECT_STRENGTH_DEFAULT;
                       this.brightnessVal = BRIGHTNESS_DEFAULT;
                       this.contrastVal = CONTRAST_DEFAULT;
                       this.saturationVal = SATURATION_DEFAULT;
                       this.subpixelRender = SUBPIXEL_RENDER_DEFAULT;
                       this.gammaCorrect = GAMMA_CORRECT_DEFAULT;
    this.ditherEnabled = DITHER_DEFAULT;
    this.screenSizeIndex = SCREEN_SIZE_DEFAULT_INDEX;
    this.speedMultIndex = 0;
                       this.saveDisplayFilter();
                    })
                }
                .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 12 })
              }
            }
          }
        }
        .padding({ left: 16, right: 16 })

        // ── 交互 ──
        ListItem() {
          Column() {
            SectionHeader({ title: '交互' })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                SRow({ label: '按键震动' }) {
                  Toggle({ type: ToggleType.Switch, isOn: this.hapticEnabled })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .onChange((isOn: boolean) => { this.saveHaptic(isOn); })
                }
                SDivider()
                Row() {
                  Text('震动强度')
                    .fontSize(16)
                    .fontColor(this.hapticEnabled ? $r('app.color.settings_label_color') : $r('app.color.settings_haptic_disabled'))
                    .layoutWeight(1)
                  SSelect({
                    opts: STRENGTH_OPTIONS,
                    selected: this.strengthIndex,
                    value: STRENGTH_OPTIONS[this.strengthIndex].value as string,
                    onSelect: (index: number) => { this.saveStrength(index); }
                  })
                }
                .width('100%')
                .height(ROW_H)
                .alignItems(VerticalAlign.Center)
                .padding({ left: PAD_H, right: PAD_H })
                .enabled(this.hapticEnabled)
                .opacity(this.hapticEnabled ? 1 : 0.35)
                SDesc({ text: '调节按键触控时的震动反馈力度，选择后即时体验。' })
                SDivider()
                SRow({ label: '手柄映射' }) {
                  SSelect({
                    opts: GAMEPAD_MAP_OPTIONS,
                    selected: this.gamepadMapIndex,
                    value: GAMEPAD_MAP_OPTIONS[this.gamepadMapIndex].value as string,
                    onSelect: (index: number) => { this.saveGamepadMap(index); }
                  })
                }
                SDesc({ text: '经典:A=确认 B=返回; 方向优先:A=确认 DPad=方向; 数字键盘:A=1 B=2 X=3 Y=4' })
              }
            }
          }
        }
        .padding({ left: 16, right: 16 })

        // ── 游戏震动 ──
        ListItem() {
          Column() {
            SectionHeader({ title: '游戏震动' })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                SRow({ label: '震动强度' }) {
                  SSelect({
                    opts: SHAKE_INTENSITY_OPTIONS,
                    selected: this.shakeIntensityIndex,
                    value: SHAKE_INTENSITY_OPTIONS[this.shakeIntensityIndex].value as string,
                    onSelect: (index: number) => { this.saveShakeIntensity(index); }
                  })
                }
                SDesc({ text: '调节游戏中 mr_startShake 触发的振动强度。轻柔=短振, 强烈=长振+闹钟模式。即时生效。' })
              }
            }
          }
        }
        .padding({ left: 16, right: 16 })

        // ── 动感 ──
        ListItem() {
          Column() {
            SectionHeader({ title: '动感' })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                SSliderLabel({ label: '灵敏度', valueText: `${this.sensitivity.toFixed(1)}x` })
                SSlider({
                  value: this.sensitivity, min: 0.2, max: 3.0, step: 0.1,
                  onChange: (v: number) => { this.saveSensitivity(v); }
                })
                SDesc({ text: '调节加速度传感器灵敏度倍率，1.0 为默认值。值越大，动感游戏中球的移动越灵敏。需重启游戏后生效。' })
              }
            }
          }
        }
        .padding({ left: 16, right: 16 })

        // ── 关于 ──
        ListItem() {
          Column() {
            SectionHeader({ title: '关于' })
            GlassPanel({ blurRadius: 30, panelBorderRadius: CARD_RADIUS, panelBorderColor: $r('app.color.settings_card_border'), panelBgColor: $r('app.color.settings_card_bg'), panelBorderWidth: 0.5 }) {
              Column() {
                Column() {
                  Text('VMRP')
                    .fontSize(20)
                    .fontColor($r('app.color.settings_about_title'))
                    .fontWeight(FontWeight.Bold)
                  Text('MRP 模拟器')
                    .fontSize(13)
                    .fontColor($r('app.color.settings_about_subtitle'))
                    .margin({ top: 2 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ left: PAD_H, right: PAD_H, top: 16, bottom: 8 })
                Text('VMRP 是一款基于 Mythroad 平台的 MRP 应用模拟器，可在 HarmonyOS 设备上运行经典的 MRP 小游戏与应用。')
                  .fontSize(14)
                  .fontColor($r('app.color.settings_desc_color'))
                  .lineHeight(22)
                  .width('100%')
                  .padding({ left: PAD_H, right: PAD_H, bottom: 16 })
              }
            }
          }
        }
        .padding({ left: 16, right: 16 })

        // ── 数据管理 ──
        ListItem() {
          Column() {
            SectionHeader({ title: '数据管理' })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                Column() {
                  Button('备份数据')
                    .width('100%').height(44).fontSize(16)
                    .fontColor('#FFFFFF').backgroundColor($r('app.color.settings_btn_deep_bg')).borderRadius(12)
                    .onClick(() => { this.doBackup(); })
                }
                .padding({ left: PAD_H, right: PAD_H, top: 10, bottom: 0 })
                Text('将游戏、存档和缓存打包为 zip 保存到下载目录')
                  .fontSize(12).fontColor($r('app.color.settings_desc_color'))
                  .margin({ left: PAD_H, right: PAD_H, top: 6, bottom: 0 })
                SDivider()
                Column() {
                  Button('恢复数据')
                    .width('100%').height(44).fontSize(16)
                    .fontColor('#FFFFFF').backgroundColor($r('app.color.settings_btn_deep_bg')).borderRadius(12)
                    .onClick(() => { this.confirmRestore(); })
                }
                .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 0 })
                Text('从 zip 文件导入文件到内存卡(沙箱),同名覆盖')
                  .fontSize(12).fontColor($r('app.color.settings_desc_color'))
                  .margin({ left: PAD_H, right: PAD_H, top: 6, bottom: 0 })
                SDivider()
                Column() {
                  Button('导入游戏')
                    .width('100%').height(44).fontSize(16)
                    .fontColor('#FFFFFF').backgroundColor($r('app.color.settings_btn_deep_bg')).borderRadius(12)
                    .onClick(() => { this.doImportMrp(); })
                }
                .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 0 })
                Text('批量导入 .mrp 游戏文件到内存卡')
                  .fontSize(12).fontColor($r('app.color.settings_desc_color'))
                  .margin({ left: PAD_H, right: PAD_H, top: 6, bottom: 10 })
              }
            }
          }
        }
        .padding({ left: 16, right: 16 })

        // ── 危险操作 ──
        ListItem() {
          Column() {
            SectionHeader({ title: '' })
            GlassPanel({ blurRadius: 30, panelBorderRadius: CARD_RADIUS, panelBorderColor: $r('app.color.settings_card_border'), panelBgColor: $r('app.color.settings_card_bg'), panelBorderWidth: 0.5 }) {
              Column() {
                Column() {
                  Button('清空游戏文件')
                    .width('100%').height(48).fontSize(16)
                    .fontColor($r('app.color.accent_color')).backgroundColor($r('app.color.settings_danger_bg')).borderRadius(12)
                    .onClick(() => { this.confirmClearFiles(); })
                }
                .padding({ left: PAD_H, right: PAD_H, top: 8, bottom: 4 })
                SDivider()
                Column() {
                  Button('恢复默认设置')
                    .width('100%').height(48).fontSize(16)
                    .fontColor($r('app.color.accent_color')).backgroundColor($r('app.color.settings_danger_bg')).borderRadius(12)
                    .onClick(() => { this.resetDefaults(); })
                }
                .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 8 })
              }
            }
          }
        }
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 0, right: 0, top: 4, bottom: this.avoidData.bottomVp })
      .clip(false)
      .cachedCount(2, true)
      .expandSafeArea()
    }
    .titleBar({
      content: { title: { mainTitle: '设置' } },
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
    .backgroundColor($r('app.color.immersive_bg'))
    .bindToScrollable([this.listScroller])
    .systemTransition(NavigationSystemTransitionType.SLIDE_BOTTOM)
    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
    })
  }
}

@Builder
export function SettingsBuilder() {
  SettingsPage()
}

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
      .fontColor($r('app.color.settings_about_title'))
      .fontWeight(FontWeight.Medium)
      .margin({ top: 20, bottom: 6 })
    Text('将保存为 zip 文件到下载目录，同名文件将被覆盖')
      .fontSize(12)
      .fontColor($r('app.color.settings_desc_color'))
      .margin({ bottom: 14 })
    TextInput({ text: $$.fileName })
      .onChange((v: string) => { $$.fileName = v; })
      .width('85%')
      .height(44)
      .fontSize(15)
      .backgroundColor($r('app.color.settings_dialog_input_bg'))
      .fontColor($r('app.color.settings_about_title'))
      .borderRadius(10)
    Row() {
      Button('取消')
        .width(100).height(40)
        .backgroundColor($r('app.color.settings_cancel_btn_bg')).fontColor($r('app.color.settings_cancel_btn_fg'))
        .onClick(() => { $$.onCancel(); })
      Button('备份')
        .width(100).height(40)
        .backgroundColor($r('app.color.accent_color')).fontColor('#FFFFFF')
        .onClick(() => { $$.onConfirm($$.fileName); })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceEvenly)
    .margin({ top: 16, bottom: 20 })
  }
  .width('82%')
  .backgroundColor($r('app.color.settings_dialog_bg'))
  .borderRadius(16)
}
