/*
 * Index.ets - vmrp 鸿蒙主界面。
 *
 * 布局：
 *   - XComponent（id=vmrp_screen）：承载 native EGL/GLES 渲染 + 接收触摸事件。
 *   - 控制按钮：选择 MRP 文件、方向键、数字键、左右软键、确认键。
 *   - 文本编辑弹层：native 请求编辑时显示 TextInput。
 *
 * 渲染：XComponent 内部由 native 侧 EGL 渲染 RGB565 屏幕（240x320）。
 * 输入：触摸事件由 native XComponent 回调处理；实体按键/软键盘走 sendKey。
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import {
  VmrpEngineTs, VMRP_KEY_PRESS, VMRP_KEY_RELEASE,
  MR_KEY_UP, MR_KEY_DOWN, MR_KEY_LEFT, MR_KEY_RIGHT,
  MR_KEY_SELECT, MR_KEY_SOFTLEFT, MR_KEY_SOFTRIGHT,
  MR_KEY_STAR, MR_KEY_POUND
} from '../vmrp/VmrpEngine';
import { VmrpAssets } from '../vmrp/VmrpAssets';

@Entry
@Component
struct Index {
  @State status: string = '未启动';
  @State running: boolean = false;
  @State showEdit: boolean = false;
  @State editText: string = '';
  private engine: VmrpEngineTs = new VmrpEngineTs();

  aboutToAppear(): void {
    this.bootstrap();
  }

  async bootstrap(): Promise<void> {
    try {
      this.status = '正在加载 native 模块...';
      await this.engine.init();
      this.status = 'native 模块已加载';
      const ctx = getContext(this) as common.UIAbilityContext;

      // 1. 解压内置 mythroad 运行时到沙箱。
      this.status = '正在准备运行时资源...';
      const workDir = await VmrpAssets.ensureRuntime(ctx);
      this.status = `工作目录就绪`;

      // 2. 加载预构建 libvmrp.so。
      //    libvmrp.so 与 libentry.so 一起打包在模块 libs/<abi>/，运行时
      //    解压到应用沙箱 lib 目录，dlopen 用 soname 即可。
      let ok = this.engine.loadLib('libvmrp.so');
      this.status = `loadLib(libvmrp.so) = ${ok}`;
      if (!ok) {
        ok = this.engine.loadLib(`${ctx.bundleCodeDir}/lib/arm64/libvmrp.so`);
        this.status = `loadLib(绝对路径) = ${ok}`;
      }
      if (!ok) {
        this.status = '加载 libvmrp.so 失败';
        return;
      }

      // 3. 设置默认屏幕（240x320）和工作目录。
      this.engine.setScreen(240, 320);
      this.engine.setWorkDir(workDir);

      // 4. 注册编辑回调：native 检测到 MRP 请求编辑时回调此处。
      this.engine.setEditCallback(() => {
        this.showEdit = true;
        this.editText = '';
      });
      this.status = '就绪，请选择 MRP 文件';
    } catch (e) {
      // ArkTS 对 Error 做 JSON.stringify 会得到 {}，用 message/businessError 更可读。
      const err = e as Error;
      const msg = err?.message ?? String(e);
      this.status = `初始化失败: ${msg}`;
      console.error(`vmrp bootstrap failed: ${msg}`);
    }
  }

  // 直接启动内置 dsm_gm.mrp（无需文件选择器），用于验证核心运行路径。
  async startDefault(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      // ensureRuntime 返回 files 根（chdir 目标，dsmWorkPath="mythroad/" 据此拼接）。
      const workDir = await VmrpAssets.ensureRuntime(ctx);
      // mrp 文件在 mythroad 子目录下（绝对路径，不受 dsmWorkPath 影响）。
      const dst = `${VmrpAssets.getMythroadDir(ctx)}/dsm_gm.mrp`;
      this.status = `启动默认: ${dst}`;
      const r = this.engine.start(dst, 'start.mr', '_dsm');
      this.running = this.engine.isRunning();
      this.status = `启动结果: ${r}, 运行: ${this.running}`;
    } catch (e) {
      const err = e as Error;
      this.status = `启动失败: ${err?.message ?? String(e)}`;
    }
  }

  // 选择并加载 MRP 文件。
  async pickAndStart(): Promise<void> {
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['.mrp'];
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.select(opt);
      if (!uris || uris.length === 0) return;
      const ctx = getContext(this) as common.UIAbilityContext;
      const dst = await VmrpAssets.importMrp(ctx, uris[0]);
      this.status = `启动: ${dst}`;
      const r = this.engine.start(dst, 'start.mr', '_dsm');
      this.running = this.engine.isRunning();
      this.status = `启动结果: ${r}, 运行: ${this.running}`;
    } catch (e) {
      this.status = `选择失败: ${JSON.stringify(e)}`;
    }
  }

  // 触发一次按键（按下立即抬起）。
  tapKey(key: number): void {
    this.engine.sendKey(VMRP_KEY_PRESS, key);
    this.engine.sendKey(VMRP_KEY_RELEASE, key);
  }

  build() {
    Column() {
      // 顶部状态栏
      Text(this.status)
        .fontSize(14)
        .width('100%')
        .padding(8)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row() {
        Button('选择 MRP')
          .onClick(() => this.pickAndStart())
        Button('启动默认')
          .onClick(() => this.startDefault())
        Button(this.running ? '运行中' : '已停止')
          .enabled(false)
          .opacity(0.6)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding(4)

      // XComponent 屏幕：native 模块名 "entry" 对应 libentry.so。
      // id 必须与 native 侧 OH_NATIVE_XCOMPONENT_OBJ 的 XComponent 匹配。
      XComponent({
        id: 'vmrp_screen',
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .width(240)
        .height(320)
        .backgroundColor(Color.Black)

      // 方向键 + 功能键
      Grid() {
        GridItem() { Button('↑').fontSize(20).onClick(() => this.tapKey(MR_KEY_UP)) }
        GridItem() { Button('←').fontSize(20).onClick(() => this.tapKey(MR_KEY_LEFT)) }
        GridItem() { Button('确认').fontSize(14).onClick(() => this.tapKey(MR_KEY_SELECT)) }
        GridItem() { Button('→').fontSize(20).onClick(() => this.tapKey(MR_KEY_RIGHT)) }
        GridItem() { Button('↓').fontSize(20).onClick(() => this.tapKey(MR_KEY_DOWN)) }
        GridItem() { Button('左软').fontSize(14).onClick(() => this.tapKey(MR_KEY_SOFTLEFT)) }
        GridItem() { Button('右软').fontSize(14).onClick(() => this.tapKey(MR_KEY_SOFTRIGHT)) }
      }
      .columnsTemplate('1fr 1fr 1fr')
      .width('100%')
      .height(180)
      .padding(4)

      // 数字键
      Grid() {
        ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, MR_KEY_STAR, 0, MR_KEY_POUND], (k: number) => {
          GridItem() {
            Button(`${k === MR_KEY_STAR ? '*' : k === MR_KEY_POUND ? '#' : k}`)
              .fontSize(16)
              .onClick(() => this.tapKey(k))
          }
        })
      }
      .columnsTemplate('1fr 1fr 1fr')
      .width('100%')
      .height(150)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)

    // 文本编辑弹层（native 请求编辑时显示）
    .bindSheet($$this.showEdit, this.buildEditSheet(), {
      height: 260,
      dragBar: true
    })
  }

  @Builder
  buildEditSheet() {
    Column() {
      Text('请输入文字')
        .fontSize(16)
        .margin(8)
      TextInput({ text: this.editText })
        .onChange((v: string) => { this.editText = v; })
        .width('90%')
      Row() {
        Button('取消')
          .onClick(() => {
            this.engine.cancelEdit();
            this.showEdit = false;
          })
        Button('确定')
          .onClick(() => {
            this.engine.submitEdit(this.editText);
            this.showEdit = false;
          })
      }
      .margin(8)
    }
    .width('100%')
  }
}
