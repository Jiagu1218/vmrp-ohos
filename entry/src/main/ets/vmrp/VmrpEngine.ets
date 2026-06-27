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
  start as nativeStart, stop as nativeStop, sendKey as nativeSendKey,
  submitEdit as nativeSubmitEdit, cancelEdit as nativeCancelEdit,
  isRunning as nativeIsRunning, setEditCallback as nativeSetEditCallback
} from 'libentry.so';

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

  start(mrpPath: string, ext: string, entry: string): number {
    return nativeStart(mrpPath, ext, entry);
  }

  stop(): void {
    nativeStop();
  }

  sendKey(type: number, key: number): number {
    return nativeSendKey(type, key);
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

  setEditCallback(cb: () => void): void {
    nativeSetEditCallback(cb);
  }
}
