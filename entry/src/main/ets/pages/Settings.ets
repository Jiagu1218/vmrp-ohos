import { AppStorageV2, ComponentContent, LengthMetrics, display } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { HdsNavDestination, HdsNavDestinationAttribute, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { AvoidData } from '../common/AvoidData';
import { gAbilityContext } from '../entryability/EntryAbility';
import { HapticManager, HapticState, HapticStrength } from '../common/HapticManager';
import { VmrpEngineTs } from '../vmrp/VmrpEngine';
import { VmrpAssets, Sf2Info } from '../vmrp/VmrpAssets';
import { ImmersiveLightWrapper } from '../common/ImmersiveLightWrapper';
import { GlassPanel } from '../common/GlassPanel';
import { SectionHeader, SDivider, SDesc, SRow, SSliderLabel, SSlider, SSelect, CARD_RADIUS, PAD_H, ROW_H, DnsMapEntry, DnsMapListDialogParams, DnsMapListDialogBuilder } from '../components/SettingsControls';
import { GpBinding, GamepadDialogParams, GamepadDialogBuilder, defaultBindings, bindingsToJson, jsonToBindings, GAMEPAD_PRESET_OPTIONS } from '../components/GamepadBinding';

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
  { value: $r('app.string.haptic_gentle') }, { value: $r('app.string.haptic_moderate') }, { value: $r('app.string.haptic_strong') }
];
const STRENGTH_VALUES: HapticStrength[] =
  [HapticStrength.LIGHT, HapticStrength.MEDIUM, HapticStrength.STRONG];
const SHAKE_INTENSITY_OPTIONS: SelectOption[] = [
  { value: $r('app.string.haptic_gentle') }, { value: $r('app.string.haptic_moderate') }, { value: $r('app.string.haptic_strong') }
];
const SHAKE_INTENSITY_VALUES: number[] = [0, 1, 2];
const DISPLAY_FILTER_OPTIONS: SelectOption[] = [
  { value: $r('app.string.filter_original') }, { value: $r('app.string.filter_smooth') }, { value: $r('app.string.filter_edge_aa') }, { value: $r('app.string.filter_advanced_aa') }, { value: $r('app.string.filter_ai_upscale') }
];
const DISPLAY_FILTER_VALUES: number[] = [0, 1, 2, 3, 4];
const SCREEN_EFFECT_OPTIONS: SelectOption[] = [
  { value: $r('app.string.effect_off') }, { value: $r('app.string.effect_crt') }, { value: $r('app.string.effect_lcd_grid') }, { value: $r('app.string.effect_scanline') }
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
const KEY_GAMEPAD_BINDINGS = 'gamepad_bindings';
const KEY_DARK_MODE = 'dark_mode';
const KEY_FOLLOW_SYSTEM = 'follow_system';
const SPEED_OPTIONS: SelectOption[] = [
  { value: $r('app.string.speed_1x') }, { value: $r('app.string.speed_2x') }, { value: $r('app.string.speed_3x') }, { value: $r('app.string.speed_4x') }
];
const SPEED_VALUES: number[] = [1, 2, 3, 4];
const KEY_DNS_MAP = 'dns_map';
const KEY_ACTIVE_SF2 = 'active_sf2';
const DEFAULT_SF2_NAME = 'TimGM6mb.sf2';
const DEFAULT_DNS_MAP: DnsMapEntry[] = [
  { original: 'wap.skmeg.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'rop.skymobiapp.com', target: '127.0.0.1', port: 18088, enabled: true },
  { original: 'spd.skymobiapp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'freeads.51mrp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'proxy.51mrp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'proxy2.51mrp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'help.proxy.51mrp.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: 'dmrp.wapproxy.sky-mobi.com', target: '159.75.119.124', port: 0, enabled: true },
  { original: '211.155.236.18', target: '159.75.119.124', port: 0, enabled: true },
];

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
  @Local gpBindings: GpBinding[] = defaultBindings();
  @Local xengineMode: number = 0;
  @Local darkMode: boolean = true;
  @Local followSystem: boolean = true;
  @Local currentBp: string = 'sm';
  @Local dnsMapEntries: DnsMapEntry[] = [];
  @Local sf2Files: Sf2Info[] = [];
  @Local activeSf2Name: string = DEFAULT_SF2_NAME;
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
    this.loadSf2List();
    try { this.xengineMode = this.engine.getXengineUpscaleMode(); } catch (_e) {}
    try {
      const d = display.getDefaultDisplaySync();
      const w = d.width / d.densityPixels;
      if (w >= 520) { this.currentBp = 'md'; } else { this.currentBp = 'sm'; }
    } catch (_e) { this.currentBp = 'sm'; }
  }

  private showPrivacyPolicy(): void {
    const ctx = gAbilityContext;
    if (!ctx) return;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: 'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2008959737680402752'
    };
    ctx.startAbility(want).catch((_err: Error) => {});
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
      let screenIdx = -1;
      for (let i = 0; i < SCREEN_SIZE_W.length; i++) {
        if (SCREEN_SIZE_W[i] === sw && SCREEN_SIZE_H[i] === sh) { screenIdx = i; break; }
      }
      this.screenSizeIndex = screenIdx >= 0 ? screenIdx : SCREEN_SIZE_DEFAULT_INDEX;
      const speedMult = pref.getSync(KEY_SPEED_MULT, 1) as number;
      this.speedMultIndex = SPEED_VALUES.indexOf(speedMult);
      if (this.speedMultIndex < 0) this.speedMultIndex = 0;
      this.loadGpBindings(pref);
      this.darkMode = pref.getSync(KEY_DARK_MODE, true) as boolean;
      this.followSystem = pref.getSync(KEY_FOLLOW_SYSTEM, true) as boolean;
      this.loadDnsMap(pref);
      this.activeSf2Name = pref.getSync(KEY_ACTIVE_SF2, DEFAULT_SF2_NAME) as string;
      if (this.followSystem) {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        if (ctx) {
          this.darkMode = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
        }
      }
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

  saveGpBindings(): void {
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_GAMEPAD_BINDINGS, bindingsToJson(this.gpBindings));
    pref.flush();
  }

  applyColorMode(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!ctx) return;
    const appCtx = ctx.getApplicationContext();
    if (this.followSystem) {
      appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } else {
      appCtx.setColorMode(this.darkMode ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    }
  }

  saveDarkMode(isDark: boolean): void {
    this.darkMode = isDark;
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_DARK_MODE, isDark);
    pref.flush();
    if (!this.followSystem) {
      this.applyColorMode();
    }
  }

  saveFollowSystem(follow: boolean): void {
    this.followSystem = follow;
    const pref = this.getPref();
    if (!pref) return;
    pref.putSync(KEY_FOLLOW_SYSTEM, follow);
    pref.flush();
    this.applyColorMode();
  }

  loadGpBindings(pref: preferences.Preferences): void {
    try {
      const raw = pref.getSync(KEY_GAMEPAD_BINDINGS, '') as string;
      if (raw.length > 0) {
        this.gpBindings = jsonToBindings(raw);
      } else {
        this.gpBindings = defaultBindings();
      }
    } catch (_e) {
      this.gpBindings = defaultBindings();
    }
  }

  loadDnsMap(pref: preferences.Preferences): void {
    try {
      const raw = pref.getSync(KEY_DNS_MAP, '') as string;
      if (raw.length > 0) {
        const arr: DnsMapEntry[] = JSON.parse(raw) as DnsMapEntry[];
        if (arr.length > 0) {
          this.dnsMapEntries = arr;
          return;
        }
      }
    } catch (_e) {}
    // No saved DNS map — use defaults
    this.dnsMapEntries = DEFAULT_DNS_MAP.map((e: DnsMapEntry) => {
      const entry: DnsMapEntry = { original: e.original, target: e.target, port: e.port, enabled: e.enabled };
      return entry;
    });
  }

  saveDnsMap(): void {
    const pref = this.getPref();
    if (!pref) return;
    const json = JSON.stringify(this.dnsMapEntries.map((e: DnsMapEntry): Record<string, Object> => {
      const obj: Record<string, Object> = {
        'o': e.original,
        't': e.target,
        'p': e.port,
        'e': e.enabled
      };
      return obj;
    }));
    pref.putSync(KEY_DNS_MAP, json);
    pref.flush();
    // Convert to C-side format and apply immediately
    this.applyDnsMap();
  }

  applyDnsMap(): void {
    const cMap = this.dnsMapEntries
      .filter((e: DnsMapEntry) => e.enabled && e.original.length > 0 && e.target.length > 0)
      .map((e: DnsMapEntry) => {
        if (e.port > 0) {
          return `${e.original}->${e.target}:${e.port}`;
        }
        return `${e.original}->${e.target}`;
      })
      .join(';');
    if (cMap.length > 0) {
      this.engine.setDnsMap(cMap);
    }
  }

  resetDnsMap(): void {
    this.dnsMapEntries = DEFAULT_DNS_MAP.map((e: DnsMapEntry) => {
      const entry: DnsMapEntry = { original: e.original, target: e.target, port: e.port, enabled: e.enabled };
      return entry;
    });
    this.saveDnsMap();
  }

  openDnsMapListDialog(): void {
    const uiCtx = this.getUIContext();
    const prompt = uiCtx.getPromptAction();
    const params: DnsMapListDialogParams = {
      onClose: () => {
        prompt.closeCustomDialog(contentNode);
        // 弹窗自己已写 preferences，这里重新加载 + 应用
        const pref = this.getPref();
        if (pref) {
          this.loadDnsMap(pref);
        }
      }
    };
    const contentNode = new ComponentContent(uiCtx, wrapBuilder(DnsMapListDialogBuilder), params);
    prompt.openCustomDialog(contentNode, { alignment: DialogAlignment.Center, autoCancel: true });
  }

  loadSf2List(): void {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) return;
    const pref = this.getPref();
    if (pref) {
      this.activeSf2Name = pref.getSync(KEY_ACTIVE_SF2, DEFAULT_SF2_NAME) as string;
    }
    this.sf2Files = VmrpAssets.listSf2Files(ctx, this.activeSf2Name);
  }

  async doImportSf2(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) return;
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['.sf2'];
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.select(opt);
      if (!uris || uris.length === 0) return;
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.settings_toast_sf2_importing') });
      const ok = await VmrpAssets.importSf2(ctx, uris[0]);
      if (ok) {
        this.loadSf2List();
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.settings_toast_sf2_import_ok'), duration: 2500 });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.settings_toast_sf2_import_failed'), duration: 2500 });
      }
    } catch (e) {
      console.error(`doImportSf2 failed: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.settings_toast_sf2_import_failed'), duration: 2500 });
    }
  }

  selectSf2(name: string): void {
    this.activeSf2Name = name;
    const pref = this.getPref();
    if (pref) {
      pref.putSync(KEY_ACTIVE_SF2, name);
      pref.flush();
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      this.engine.setActiveSf2(ctx.filesDir, name);
    }
    // Refresh list to update active indicator
    this.loadSf2List();
    this.getUIContext().getPromptAction().showToast({ message: $r('app.string.settings_toast_sf2_selected'), duration: 2000 });
  }

  confirmDeleteSf2(name: string): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.settings_dialog_title_delete_sf2'),
      message: `确定删除「${name}」吗？此操作不可恢复。`,
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: { value: $r('app.string.btn_cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.btn_delete'),
        fontColor: $r('app.color.accent_color'),
        action: () => {
          const ctx = this.getUIContext().getHostContext();
          if (!ctx) return;
          const ok = VmrpAssets.deleteSf2(ctx, name);
          if (ok) {
            // If deleting the active SF2, fall back to default
            if (name === this.activeSf2Name) {
              this.activeSf2Name = DEFAULT_SF2_NAME;
              const pref = this.getPref();
              if (pref) {
                pref.putSync(KEY_ACTIVE_SF2, DEFAULT_SF2_NAME);
                pref.flush();
              }
              this.engine.setActiveSf2(ctx.filesDir, DEFAULT_SF2_NAME);
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.settings_toast_sf2_fallback'), duration: 2500 });
            }
            this.loadSf2List();
          }
        }
      }
    });
  }

  formatFileSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  openGamepadDialog(): void {
    const uiCtx = this.getUIContext();
    const prompt = uiCtx.getPromptAction();
    const params: GamepadDialogParams = {
      initialBindings: this.gpBindings,
      onConfirm: (bindings: GpBinding[]) => {
        this.gpBindings = bindings;
        this.saveGpBindings();
      },
      onClose: () => {
        prompt.closeCustomDialog(contentNode);
      }
    };
    const contentNode = new ComponentContent(uiCtx, wrapBuilder(GamepadDialogBuilder), params);
    prompt.openCustomDialog(contentNode, {
      alignment: DialogAlignment.Center,
      autoCancel: true,
      offset: { dx: 0, dy: 0 }
    });
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
    this.darkMode = true;
    this.followSystem = true;
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
    pref.putSync(KEY_DARK_MODE, true);
    pref.putSync(KEY_FOLLOW_SYSTEM, true);
    pref.putSync(KEY_DNS_MAP, '');
    pref.putSync(KEY_ACTIVE_SF2, DEFAULT_SF2_NAME);
    pref.flush();
    this.applyDisplayFilter();
    this.applyColorMode();
    this.applyDnsMap();
    // Reset DNS map to defaults
    this.dnsMapEntries = DEFAULT_DNS_MAP.map((e: DnsMapEntry) => {
      const entry: DnsMapEntry = { original: e.original, target: e.target, port: e.port, enabled: e.enabled };
      return entry;
    });
    this.activeSf2Name = DEFAULT_SF2_NAME;
    this.loadSf2List();
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      HapticManager.saveEnabledPref(ctx, true);
      HapticManager.saveStrengthPref(ctx, HapticStrength.MEDIUM);
    }
  }

  confirmClearFiles(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.dialog_title_clear'),
      message: $r('app.string.dialog_msg_clear'),
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: { value: $r('app.string.btn_cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.btn_clear'),
        fontColor: $r('app.color.accent_color'),
        action: () => {
          try { this.engine.stop(); } catch (_e) {}
          const ctx = this.getUIContext().getHostContext();
          if (!ctx) return;
          const ok = VmrpAssets.clearWorkDir(ctx);
          this.getUIContext().getPromptAction().showToast({
            message: ok ? $r('app.string.toast_cleared') : $r('app.string.toast_clear_failed'), duration: 2500
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
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_backing_up') });
      const ok = await VmrpAssets.backupToZip(ctx, destUri, fileName);
      this.getUIContext().getPromptAction().showToast({ message: ok ? $r('app.string.toast_backup_ok') : $r('app.string.toast_backup_failed'), duration: 2500 });
    } catch (e) {
      console.error(`doBackup failed: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_backup_failed'), duration: 2500 });
    }
  }

  confirmRestore(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.dialog_title_restore'),
      message: $r('app.string.dialog_msg_restore'),
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: { value: $r('app.string.btn_cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.dialog_btn_select_backup'),
        fontColor: $r('app.color.accent_color'),
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
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_restoring') });
            const ok = await VmrpAssets.restoreFromZip(ctx, srcUri);
            this.getUIContext().getPromptAction().showToast({
              message: ok ? $r('app.string.toast_restore_ok') : $r('app.string.toast_restore_failed'), duration: 2500
            });
            if (ok) {
              const abilityCtx = ctx as common.UIAbilityContext;
              abilityCtx.terminateSelf();
            }
          } catch (e) {
            console.error(`doRestore failed: ${JSON.stringify(e)}`);
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_restore_failed'), duration: 2500 });
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
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_importing') });
      const count = await VmrpAssets.importMrpBatch(ctx, uris);
      this.getUIContext().getPromptAction().showToast({
        message: count > 0 ? $r('app.string.toast_import_ok', count) : $r('app.string.toast_import_failed'), duration: 2500
      });
    } catch (e) {
      console.error(`doImportMrp failed: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_import_failed'), duration: 2500 });
    }
  }

  build() {
    HdsNavDestination() {
      WaterFlow({ scroller: this.listScroller }) {
        FlowItem() {
          Column() {
            SectionHeader({ title: $r('app.string.settings_section_emulator') })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
               Column() {
              
                 SRow({ label: $r('app.string.settings_label_resolution') }) {
                   SSelect({
                     opts: SCREEN_SIZE_OPTIONS,
                     selected: this.screenSizeIndex,
                     value: SCREEN_SIZE_OPTIONS[this.screenSizeIndex].value as string,
                     onSelect: (index: number) => { this.saveScreenSize(index); }
                   })
                 }
                 SDesc({ text: $r('app.string.settings_desc_resolution') })
                 SDivider()
                 SRow({ label: $r('app.string.settings_label_memory') }) {
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
                 SDesc({ text: $r('app.string.settings_desc_memory') })
                 SDivider()
                  SRow({ label: $r('app.string.settings_label_speed') }) {
                   SSelect({
                     opts: SPEED_OPTIONS,
                     selected: this.speedMultIndex,
                     value: SPEED_OPTIONS[this.speedMultIndex].value as string,
                     onSelect: (index: number) => {
                       this.saveSpeedMult(index);
                     }
                   })
                 }
                  SDesc({ text: $r('app.string.settings_desc_speed') })
                }
             }
            }
          }
          .width('100%')

         FlowItem() {
           Column() {
             SectionHeader({ title: $r('app.string.settings_section_display') })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                SRow({ label: $r('app.string.settings_label_filter') }) {
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
                SDesc({ text: this.xengineMode > 0
                  ? (this.xengineMode === 2 ? $r('app.string.settings_desc_filter_ai_neural_full') : $r('app.string.settings_desc_filter_ai_spatial_full'))
                  : $r('app.string.settings_desc_filter_default') })

                SDivider()
                SRow({ label: $r('app.string.settings_label_screen_effect') }) {
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
                SDesc({ text: $r('app.string.settings_desc_screen_effect') })

                SDivider()
                SSliderLabel({ label: $r('app.string.settings_label_effect_strength'), valueText: `${this.screenEffectStrength.toFixed(2)}` })
                SSlider({
                  value: this.screenEffectStrength, min: 0.0, max: 1.0, step: 0.05,
                  onChange: (v: number) => { this.screenEffectStrength = v; this.saveDisplayFilter(); }
                })

                SDivider()
                SSliderLabel({ label: $r('app.string.settings_label_brightness'), valueText: `${this.brightnessVal.toFixed(2)}` })
                SSlider({
                  value: this.brightnessVal, min: -0.3, max: 0.3, step: 0.02,
                  onChange: (v: number) => { this.brightnessVal = v; this.saveDisplayFilter(); }
                })

                SDivider()
                SSliderLabel({ label: $r('app.string.settings_label_contrast'), valueText: `${this.contrastVal.toFixed(2)}` })
                SSlider({
                  value: this.contrastVal, min: 0.5, max: 2.0, step: 0.05,
                  onChange: (v: number) => { this.contrastVal = v; this.saveDisplayFilter(); }
                })

                SDivider()
                SSliderLabel({ label: $r('app.string.settings_label_saturation'), valueText: `${this.saturationVal.toFixed(2)}` })
                SSlider({
                  value: this.saturationVal, min: 0.0, max: 2.0, step: 0.05,
                  onChange: (v: number) => { this.saturationVal = v; this.saveDisplayFilter(); }
                })

                SDivider()
                SRow({ label: $r('app.string.settings_label_subpixel') }) {
                  Toggle({ type: ToggleType.Switch, isOn: this.subpixelRender === 1 })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .onChange((isOn: boolean) => { this.subpixelRender = isOn ? 1 : 0; this.saveDisplayFilter(); })
                }
                SDesc({ text: $r('app.string.settings_desc_subpixel') })

                SDivider()
                SRow({ label: $r('app.string.settings_label_gamma') }) {
                  Toggle({ type: ToggleType.Switch, isOn: this.gammaCorrect === 1 })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .onChange((isOn: boolean) => { this.gammaCorrect = isOn ? 1 : 0; this.saveDisplayFilter(); })
                }
                SDesc({ text: $r('app.string.settings_desc_gamma') })

                SDivider()
                SRow({ label: $r('app.string.settings_label_dither') }) {
                  Toggle({ type: ToggleType.Switch, isOn: this.ditherEnabled === 1 })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .onChange((isOn: boolean) => { this.ditherEnabled = isOn ? 1 : 0; this.saveDisplayFilter(); })
                }
                SDesc({ text: $r('app.string.settings_desc_dither') })

                SDivider()
                Column() {
                  Button($r('app.string.settings_btn_reset_display'))
                    .width('100%')
                    .height(40)
                    .fontSize(14)
                    .fontColor($r('app.color.accent_color'))
                    .backgroundColor(Color.Transparent)
                    .borderRadius(8)
                    .border({ width: 1, color: $r('app.color.settings_reset_btn_border') })
                    .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
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
          .width('100%')

         FlowItem() {
           Column() {
             SectionHeader({ title: $r('app.string.settings_section_appearance') })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                SRow({ label: $r('app.string.settings_label_follow_system') }) {
                  Toggle({ type: ToggleType.Switch, isOn: this.followSystem })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .onChange((isOn: boolean) => { this.saveFollowSystem(isOn); })
                }
                SDesc({ text: $r('app.string.settings_desc_follow_system') })
                SDivider()
                Row() {
                  Text($r('app.string.settings_label_dark_mode'))
                    .fontSize(16)
                    .fontColor($r('app.color.settings_label_color'))
                    .layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.darkMode })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .enabled(!this.followSystem)
                    .onChange((isOn: boolean) => { this.saveDarkMode(isOn); })
                }
                .width('100%')
                .height(ROW_H)
                .alignItems(VerticalAlign.Center)
                .padding({ left: PAD_H, right: PAD_H })
                .opacity(this.followSystem ? 0.55 : 1)
                 SDesc({ text: $r('app.string.settings_desc_dark_mode') })
               }
             }
            }
          }
          .width('100%')

         FlowItem() {
           Column() {
             SectionHeader({ title: $r('app.string.settings_section_interaction') })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                 SRow({ label: $r('app.string.settings_label_key_haptic') }) {
                  Toggle({ type: ToggleType.Switch, isOn: this.hapticEnabled })
                    .selectedColor($r('app.color.accent_color'))
                    .switchPointColor('#FFFFFF')
                    .onChange((isOn: boolean) => { this.saveHaptic(isOn); })
                }
                SDivider()
                Row() {
                   Text($r('app.string.settings_label_haptic_strength'))
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
                .opacity(this.hapticEnabled ? 1 : 0.55)
                SDesc({ text: $r('app.string.settings_desc_haptic_strength') })
                SDivider()
                 SRow({ label: $r('app.string.settings_label_gamepad') }) {
                     Button($r('app.string.settings_btn_gamepad_map'))
                      .height(36)
                      .fontSize(13)
                      .fontColor($r('app.color.btn_text_on_accent'))
                      .fontWeight(FontWeight.Medium)
                      .backgroundColor($r('app.color.accent_color'))
                      .borderRadius(8)
                      .onClick(() => { this.openGamepadDialog(); })
                      .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
                      .accessibilityLevel('yes')
                }
                 SDesc({ text: $r('app.string.settings_desc_gamepad') })
               }
             }
            }
          }
          .width('100%')

         FlowItem() {
           Column() {
             SectionHeader({ title: $r('app.string.settings_section_game_shake') })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                 SRow({ label: $r('app.string.settings_label_shake_intensity') }) {
                  SSelect({
                    opts: SHAKE_INTENSITY_OPTIONS,
                    selected: this.shakeIntensityIndex,
                    value: SHAKE_INTENSITY_OPTIONS[this.shakeIntensityIndex].value as string,
                    onSelect: (index: number) => { this.saveShakeIntensity(index); }
                  })
                }
                 SDesc({ text: $r('app.string.settings_desc_shake_intensity') })
               }
             }
            }
          }
          .width('100%')

         FlowItem() {
           Column() {
             SectionHeader({ title: $r('app.string.settings_section_motion') })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                SSliderLabel({ label: $r('app.string.settings_label_sensitivity'), valueText: `${this.sensitivity.toFixed(1)}x` })
                SSlider({
                  value: this.sensitivity, min: 0.2, max: 3.0, step: 0.1,
                  onChange: (v: number) => { this.saveSensitivity(v); }
                })
                 SDesc({ text: $r('app.string.settings_desc_sensitivity') })
               }
             }
            }
          }
           .width('100%')

           FlowItem() {
             Column() {
               SectionHeader({ title: $r('app.string.settings_section_dns') })
              ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
                Column() {
                  Row() {
                    Text($r('app.string.settings_section_dns'))
                      .fontSize(16)
                      .fontColor($r('app.color.settings_label_color'))
                      .fontWeight(FontWeight.Medium)
                      .layoutWeight(1)
                    Text(`${this.dnsMapEntries.length} 条映射`)
                      .fontSize(13)
                      .fontColor($r('app.color.settings_desc_color'))
                      .margin({ right: 8 })
                    Button($r('app.string.btn_set'))
                      .height(28)
                      .fontSize(13)
                      .fontColor($r('app.color.btn_text_on_accent'))
                      .fontWeight(FontWeight.Medium)
                      .backgroundColor($r('app.color.accent_color'))
                      .borderRadius(8)
                      .padding({ left: 12, right: 12 })
                      .onClick(() => { this.openDnsMapListDialog(); })
                      .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                  .padding({ left: PAD_H, right: PAD_H, top: 12, bottom: 8 })
                  SDesc({ text: $r('app.string.settings_desc_dns') })
                }
               }
             }
           }
           .width('100%')

          FlowItem() {
            Column() {
              SectionHeader({ title: $r('app.string.settings_section_sf2') })
             ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
               Column() {
                 ForEach(this.sf2Files, (item: Sf2Info, index: number) => {
                   Row() {
                      Radio({ value: item.name, group: 'sf2_group' })
                        .checked(item.isActive)
                        .onChange((isChecked: boolean) => {
                         if (isChecked) { this.selectSf2(item.name); }
                       })
                       .width(20)
                       .height(20)
                       .margin({ right: 8 })
                     Column() {
                       Text(item.name)
                         .fontSize(14)
                         .fontColor($r('app.color.settings_label_color'))
                         .fontWeight(item.isActive ? FontWeight.Bold : FontWeight.Normal)
                       Text(this.formatFileSize(item.size))
                         .fontSize(11)
                         .fontColor($r('app.color.settings_desc_color'))
                         .margin({ top: 2 })
                     }
                     .layoutWeight(1)
                     .alignItems(HorizontalAlign.Start)
                     if (item.isActive) {
                       Text($r('app.string.settings_label_active_sf2'))
                         .fontSize(11)
                         .fontColor($r('app.color.accent_color'))
                         .fontWeight(FontWeight.Medium)
                         .margin({ right: 4 })
                     }
                     if (item.isBuiltin) {
                       Text($r('app.string.settings_label_builtin'))
                         .fontSize(11)
                         .fontColor($r('app.color.settings_desc_color'))
                         .margin({ right: 4 })
                     }
                     if (!item.isBuiltin) {
                       Button() {
                         Text($r('app.string.btn_delete'))
                           .fontSize(12)
                           .fontColor($r('app.color.accent_color'))
                       }
                       .height(28)
                       .backgroundColor(Color.Transparent)
                       .border({ width: 1, color: $r('app.color.settings_reset_btn_border'), radius: 6 })
                       .padding({ left: 8, right: 8 })
                       .onClick(() => { this.confirmDeleteSf2(item.name); })
                     }
                   }
                   .width('100%')
                   .alignItems(VerticalAlign.Center)
                   .padding({ left: PAD_H, right: PAD_H, top: 8, bottom: 8 })
                 }, (_item: Sf2Info, index: number) => `${index}`)
                 SDivider()
                 Column() {
                   Button($r('app.string.settings_btn_import_sf2'))
                     .width('100%').height(44).fontSize(16)
                     .fontColor($r('app.color.btn_text_on_accent')).backgroundColor($r('app.color.settings_btn_deep_bg')).borderRadius(12)
                     .onClick(() => { this.doImportSf2(); })
                     .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
                 }
                 .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 4 })
                 SDesc({ text: $r('app.string.settings_desc_sf2') })
               }
              }
            }
          }
          .width('100%')

          FlowItem() {
            Column() {
              SectionHeader({ title: $r('app.string.settings_section_about') })
            GlassPanel({ blurRadius: 30, panelBorderRadius: CARD_RADIUS, panelBorderColor: $r('app.color.settings_card_border'), panelBgColor: $r('app.color.settings_card_bg'), panelBorderWidth: 0.5 }) {
              Column() {
                Column() {
                  Text($r('app.string.settings_about_name'))
                    .fontSize(20)
                    .fontColor($r('app.color.settings_about_title'))
                    .fontWeight(FontWeight.Bold)
                  Text($r('app.string.settings_about_subtitle'))
                    .fontSize(13)
                    .fontColor($r('app.color.settings_about_subtitle'))
                    .margin({ top: 2 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ left: PAD_H, right: PAD_H, top: 16, bottom: 8 })
                Text($r('app.string.settings_about_desc'))
                  .fontSize(14)
                  .fontColor($r('app.color.settings_desc_color'))
                  .lineHeight(22)
                  .width('100%')
                  .padding({ left: PAD_H, right: PAD_H, bottom: 8 })
                Row() {
                  Text($r('app.string.privacy_policy_link'))
                    .fontSize(14)
                    .fontColor($r('app.color.accent_color'))
                    .decoration({ type: TextDecorationType.Underline, color: $r('app.color.accent_color') })
                }
                .width('100%')
                .padding({ left: PAD_H, right: PAD_H, bottom: 16 })
                 .onClick(() => {
                   this.showPrivacyPolicy();
                 })
               }
             }
            }
          }
          .width('100%')

         FlowItem() {
           Column() {
             SectionHeader({ title: $r('app.string.settings_section_data') })
            ImmersiveLightWrapper({ radius: CARD_RADIUS, lightHeight: 80, bgColor: $r('app.color.settings_card_bg'), blurRadius: 30 }) {
              Column() {
                Column() {
                  Button($r('app.string.settings_btn_backup'))
                      .width('100%').height(44).fontSize(16)
                      .fontColor($r('app.color.btn_text_on_accent')).backgroundColor($r('app.color.settings_btn_deep_bg')).borderRadius(12)
                      .onClick(() => { this.doBackup(); })
                      .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
                      .accessibilityLevel('yes')
                }
                .padding({ left: PAD_H, right: PAD_H, top: 10, bottom: 0 })
                Text($r('app.string.settings_desc_backup'))
                  .fontSize(12).fontColor($r('app.color.settings_desc_color'))
                  .margin({ left: PAD_H, right: PAD_H, top: 6, bottom: 0 })
                SDivider()
                Column() {
                  Button($r('app.string.settings_btn_restore'))
                      .width('100%').height(44).fontSize(16)
                      .fontColor($r('app.color.btn_text_on_accent')).backgroundColor($r('app.color.settings_btn_deep_bg')).borderRadius(12)
                      .onClick(() => { this.confirmRestore(); })
                      .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
                      .accessibilityLevel('yes')
                }
                .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 0 })
                Text($r('app.string.settings_desc_restore'))
                  .fontSize(12).fontColor($r('app.color.settings_desc_color'))
                  .margin({ left: PAD_H, right: PAD_H, top: 6, bottom: 0 })
                SDivider()
                Column() {
                  Button($r('app.string.settings_btn_import'))
                      .width('100%').height(44).fontSize(16)
                      .fontColor($r('app.color.btn_text_on_accent')).backgroundColor($r('app.color.settings_btn_deep_bg')).borderRadius(12)
                      .onClick(() => { this.doImportMrp(); })
                      .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
                      .accessibilityLevel('yes')
                }
                .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 0 })
                Text($r('app.string.settings_desc_import'))
                  .fontSize(12).fontColor($r('app.color.settings_desc_color'))
                 .margin({ left: PAD_H, right: PAD_H, top: 6, bottom: 10 })
               }
             }
            }
          }
          .width('100%')

         FlowItem() {
           Column() {
             SectionHeader({ title: '' })
            GlassPanel({ blurRadius: 30, panelBorderRadius: CARD_RADIUS, panelBorderColor: $r('app.color.settings_card_border'), panelBgColor: $r('app.color.settings_card_bg'), panelBorderWidth: 0.5 }) {
              Column() {
                Column() {
                   Button($r('app.string.settings_btn_clear_files'))
                      .width('100%').height(48).fontSize(16)
                      .fontColor($r('app.color.accent_color')).backgroundColor($r('app.color.settings_danger_bg')).borderRadius(12)
                      .onClick(() => { this.confirmClearFiles(); })
                      .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
                      .accessibilityLevel('yes')
                }
                .padding({ left: PAD_H, right: PAD_H, top: 8, bottom: 4 })
                SDivider()
                Column() {
                   Button($r('app.string.settings_btn_reset_defaults'))
                      .width('100%').height(48).fontSize(16)
                      .fontColor($r('app.color.accent_color')).backgroundColor($r('app.color.settings_danger_bg')).borderRadius(12)
                      .onClick(() => { this.resetDefaults(); })
                      .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
                      .accessibilityLevel('yes')
                }
                .padding({ left: PAD_H, right: PAD_H, top: 4, bottom: 8 })
              }
            }
           }
         }
         .width('100%')
      }
      .columnsTemplate(this.currentBp === 'sm' ? '1fr' : '1fr 1fr')
      .columnsGap(12)
      .rowsGap(8)
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 16, right: 16, top: 4, bottom: this.avoidData.bottomVp })
      .clip(false)
      .expandSafeArea()
    }
    .titleBar({
      content: { title: { mainTitle: $r('app.string.settings_title') } },
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
    .onAreaChange((_old: Area, newVal: Area) => {
      // 折叠屏内屏↔外屏切换时,根据宽度更新列数(sm=1列, md=2列)
      const w = newVal.width as number;
      const newBp = w >= 520 ? 'md' : 'sm';
      if (newBp !== this.currentBp) {
        this.currentBp = newBp;
      }
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
    Text($r('app.string.dialog_title_backup_name'))
      .fontSize(17)
      .fontColor($r('app.color.settings_about_title'))
      .fontWeight(FontWeight.Medium)
      .margin({ top: 20, bottom: 6 })
    Text($r('app.string.dialog_desc_backup_name'))
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
      Button($r('app.string.btn_cancel'))
        .width(100).height(40)
        .backgroundColor($r('app.color.settings_cancel_btn_bg')).fontColor($r('app.color.settings_cancel_btn_fg'))
        .onClick(() => { $$.onCancel(); })
      Button($r('app.string.btn_backup'))
        .width(100).height(40)
        .backgroundColor($r('app.color.accent_color')).fontColor($r('app.color.btn_text_on_accent'))
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
