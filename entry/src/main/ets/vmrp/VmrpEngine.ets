/*
 * VmrpEngine.ets - vmrp native 模块的 ArkTS 封装。
 *
 * 对应 entry/src/main/cpp/vmrp_napi.cpp 导出的 NAPI 方法。
 * libvmrp.so（含 Unicorn arm-softmmu 软件模拟 ARM32）通过 XComponent native
 * 模块加载；本文件提供 ArkTS 侧的调用接口。
 *
 * MRP 屏幕默认 240x320（参考 vmrp/docs/flutter-integration.md）。
 */

// 静态导入 native 模块（libentry.so，nm_modname="entry"）。
// 类型由 entry/src/main/cpp/types/libentry/Index.d.ts 提供。
import {
  loadLib, init as nativeInit, setWorkDir as nativeSetWorkDir,
  setMemory as nativeSetMemory,
  start as nativeStart, stop as nativeStop, sendKey as nativeSendKey,
  sendMotion as nativeSendMotion,
  setMotionSensitivity as nativeSetMotionSensitivity,
  setShakeIntensity as nativeSetShakeIntensity,
  setDisplayFilter as nativeSetDisplayFilter,
  startDsmB as nativeStartDsmB, startDsmC as nativeStartDsmC,
  startDsmEx as nativeStartDsmEx,
  submitEdit as nativeSubmitEdit, cancelEdit as nativeCancelEdit,
  isRunning as nativeIsRunning, setEditCallback as nativeSetEditCallback,
  setExitCallback as nativeSetExitCallback,
  setSpeedMultiplier as nativeSetSpeedMultiplier,
  createSurfaceNode as nativeCreateSurfaceNode,
  mediaPause as nativeMediaPause, mediaResume as nativeMediaResume,
  getScreenInfo as nativeGetScreenInfo
} from 'libentry.so';

interface ScreenInfo {
  width: number;
  height: number;
  rotation: number;
}

// MRP 事件码（与 vmrp_api.h 一致）。
export const VMRP_KEY_PRESS = 0;
export const VMRP_KEY_RELEASE = 1;

// MRP 按键码（与 src/include/types.h 的 MR_KEY_* 枚举一致）。
// ArkTS strict mode 要求对象字面量有显式类型，故用独立 const。
export const MR_KEY_0 = 0;
export const MR_KEY_1 = 1;
export const MR_KEY_2 = 2;
export const MR_KEY_3 = 3;
export const MR_KEY_4 = 4;
export const MR_KEY_5 = 5;
export const MR_KEY_6 = 6;
export const MR_KEY_7 = 7;
export const MR_KEY_8 = 8;
export const MR_KEY_9 = 9;
export const MR_KEY_STAR = 10;
export const MR_KEY_POUND = 11;
export const MR_KEY_UP = 12;
export const MR_KEY_DOWN = 13;
export const MR_KEY_LEFT = 14;
export const MR_KEY_RIGHT = 15;
export const MR_KEY_POWER = 16;
export const MR_KEY_SOFTLEFT = 17;
export const MR_KEY_SOFTRIGHT = 18;
export const MR_KEY_SEND = 19;
export const MR_KEY_SELECT = 20;

export class VmrpEngineTs {
  // native 方法在模块加载时即绑定，无需额外初始化。
  async init(): Promise<void> {
    // 占位：静态 import 已在加载时完成绑定。保留 async 以兼容调用方。
  }

  loadLib(soPath: string): boolean {
    return loadLib(soPath);
  }

  setScreen(width: number, height: number): number {
    return nativeInit(width, height);
  }

  setWorkDir(dir: string): number {
    return nativeSetWorkDir(dir);
  }

  setMemory(memoryMb: number): number {
    return nativeSetMemory(memoryMb);
  }

  start(mrpPath: string, ext: string, entry: string): number {
    return nativeStart(mrpPath, ext, entry);
  }

  stop(): void {
    nativeStop();
  }

  sendKey(type: number, key: number): number {
    return nativeSendKey(type, key);
  }

  // 发送重力感应数据（mG 单位，静止平放 z≈1000）。
  sendMotion(xMg: number, yMg: number, zMg: number): number {
    return nativeSendMotion(xMg, yMg, zMg);
  }

  // 设置动感灵敏度倍率（默认 1.0，大于 1 提高灵敏度）。
  setMotionSensitivity(sensitivity: number): void {
    nativeSetMotionSensitivity(sensitivity);
  }

  setShakeIntensity(level: number): void {
    nativeSetShakeIntensity(level);
  }

  setDisplayFilter(filterType: number, screenEffect: number, screenEffectStrength: number,
                   brightness: number, contrast: number, saturation: number,
                   subpixelRender: number, gammaCorrect: number, dither: number): void {
    nativeSetDisplayFilter(filterType, screenEffect, screenEffectStrength,
                           brightness, contrast, saturation,
                           subpixelRender, gammaCorrect, dither);
  }

  // 外部移植接口: mr_start_dsmB — entry 含 *A(固化应用)/%QQ.mrp(根目录mrp)前缀
  startDsmB(entry: string): number {
    return nativeStartDsmB(entry);
  }

  // 外部移植接口: mr_start_dsmC — 同 dsmB (引擎已初始化)
  startDsmC(entry: string): number {
    return nativeStartDsmC(entry);
  }

  // 外部移植接口: mr_start_dsm_ex — 显式 path + entry
  startDsmEx(path: string, entry?: string): number {
    return nativeStartDsmEx(path, entry);
  }

  submitEdit(text: string): number {
    return nativeSubmitEdit(text);
  }

  cancelEdit(): number {
    return nativeCancelEdit();
  }

  isRunning(): boolean {
    return nativeIsRunning();
  }

  getScreenInfo(): ScreenInfo {
    return nativeGetScreenInfo();
  }

  // 暂停音频渲染(不清 PCM，可恢复)。应用切后台时调用。
  mediaPause(): void {
    nativeMediaPause();
  }

  // 恢复音频渲染。应用切回前台时调用。
  mediaResume(): void {
    nativeMediaResume();
  }

  // 注册编辑回调：native 检测到 MRP 请求编辑时回调此处，并携带待编辑的原文本用于回显。
  setEditCallback(cb: (editText: string) => void): void {
    nativeSetEditCallback(cb);
  }

  setExitCallback(cb: () => void): void {
    nativeSetExitCallback(cb);
  }

  setSpeedMultiplier(mult: number): void {
    nativeSetSpeedMultiplier(mult);
  }

  // 把 ArkTS ContentSlot 的 NodeContent 传给 native，native 在其上树时创建 XComponent 节点。
  // 必须在 aboutToAppear 时调用（UI 线程）。范式5：NDK 创建 XComponent 节点 + SurfaceHolder。
  createSurfaceNode(nodeContent: object): void {
    nativeCreateSurfaceNode(nodeContent);
  }
}
