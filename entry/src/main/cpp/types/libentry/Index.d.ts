/*
 * libentry.so 的 ArkTS 类型声明。
 * 对应 entry/src/main/cpp/vmrp_napi.cpp 中 napi_define_properties 注册的方法。
 * ArkTS 通过 import { ... } from 'libentry.so' 导入，本声明让编译器识别类型。
 */
export const loadLib: (soPath: string) => boolean;
export const init: (width: number, height: number) => number;
export const setWorkDir: (dir: string) => number;
export const setMemory: (memoryMb: number) => number;
export const start: (mrpPath: string, ext: string, entry: string) => number;
export const stop: () => void;
export const sendKey: (type: number, key: number) => number;
export const sendMotion: (x: number, y: number, z: number) => number;
export const setMotionSensitivity: (sensitivity: number) => void;
export const setShakeIntensity: (level: number) => void;
export const setDisplayFilter: (filterType: number, screenEffect: number, screenEffectStrength: number,
  brightness: number, contrast: number, saturation: number, subpixelRender: number,
  gammaCorrect: number, dither: number) => void;
export const getXengineUpscaleMode: () => number;
export const startDsmB: (entry: string) => number;
export const startDsmC: (entry: string) => number;
export const startDsmEx: (path: string, entry?: string) => number;
export const submitEdit: (text: string) => number;
export const cancelEdit: () => number;
export const isRunning: () => boolean;
interface ScreenInfo {
  width: number;
  height: number;
  rotation: number;
}
export const getScreenInfo: () => ScreenInfo;
export const mediaPause: () => void;
export const mediaResume: () => void;
export const setEditCallback: (cb: (editText: string) => void) => void;
export const setExitCallback: (cb: () => void) => void;
export const setSpeedMultiplier: (mult: number) => void;
export const createSurfaceNode: (nodeContent: object) => void;
