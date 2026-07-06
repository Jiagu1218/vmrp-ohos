import { vibrator } from '@kit.SensorServiceKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const PREF_NAME = 'vmrp_settings';
const KEY_HAPTIC = 'haptic_enabled';
const KEY_HAPTIC_STRENGTH = 'haptic_strength';

export enum HapticStrength {
  LIGHT = 0,
  MEDIUM = 1,
  STRONG = 2
}

const CLICK_EFFECTS: string[] = ['haptic.touch.light', 'haptic.touch.light', 'haptic.touch.medium'];
const PRESS_EFFECTS: string[] = ['haptic.touch.light', 'haptic.touch.medium', 'haptic.touch.heavy'];
const CLICK_DURATIONS: number[] = [10, 20, 35];
const PRESS_DURATIONS: number[] = [15, 30, 50];

@ObservedV2
export class HapticState {
  @Trace enabled: boolean = true;
  @Trace supported: boolean = true;
  @Trace strength: HapticStrength = HapticStrength.MEDIUM;
}

export class HapticManager {
  private static state: HapticState =
    AppStorageV2.connect(HapticState, 'hapticState', () => new HapticState())!;

  static getState(): HapticState {
    return HapticManager.state;
  }

  static checkSupport(): void {
    try {
      vibrator.isSupportEffect('haptic.touch.light', (err: BusinessError, state: boolean) => {
        if (err || !state) {
          HapticManager.state.supported = false;
        } else {
          HapticManager.state.supported = true;
        }
      });
    } catch (_e) {
      HapticManager.state.supported = false;
    }
  }

  static performClick(): void {
    if (!HapticManager.state.enabled) return;
    const s = HapticManager.state.strength;
    if (HapticManager.state.supported) {
      try {
        vibrator.startVibration({
          type: 'preset',
          effectId: CLICK_EFFECTS[s],
          count: 1,
        }, {
          usage: 'touch'
        });
      } catch (_e) {
        HapticManager.fallbackVibrate(CLICK_DURATIONS[s]);
      }
    } else {
      HapticManager.fallbackVibrate(CLICK_DURATIONS[s]);
    }
  }

  static performPress(): void {
    if (!HapticManager.state.enabled) return;
    const s = HapticManager.state.strength;
    if (HapticManager.state.supported) {
      try {
        vibrator.startVibration({
          type: 'preset',
          effectId: PRESS_EFFECTS[s],
          count: 1,
        }, {
          usage: 'touch'
        });
      } catch (_e) {
        HapticManager.fallbackVibrate(PRESS_DURATIONS[s]);
      }
    } else {
      HapticManager.fallbackVibrate(PRESS_DURATIONS[s]);
    }
  }

  private static fallbackVibrate(duration: number): void {
    try {
      vibrator.startVibration({
        type: 'time',
        duration: duration,
      }, {
        id: 0,
        usage: 'touch'
      });
    } catch (_e) {
    }
  }

  static async loadPref(ctx: common.Context): Promise<void> {
    try {
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      const enabled = await pref.get(KEY_HAPTIC, true);
      HapticManager.state.enabled = enabled as boolean;
      const strength = await pref.get(KEY_HAPTIC_STRENGTH, HapticStrength.MEDIUM);
      HapticManager.state.strength = strength as HapticStrength;
    } catch (_e) {
    }
    HapticManager.checkSupport();
  }

  static async saveEnabledPref(ctx: common.Context, enabled: boolean): Promise<void> {
    HapticManager.state.enabled = enabled;
    try {
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      await pref.put(KEY_HAPTIC, enabled);
      await pref.flush();
    } catch (_e) {
    }
  }

  static async saveStrengthPref(ctx: common.Context, strength: HapticStrength): Promise<void> {
    HapticManager.state.strength = strength;
    try {
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      await pref.put(KEY_HAPTIC_STRENGTH, strength);
      await pref.flush();
    } catch (_e) {
    }
  }
}
