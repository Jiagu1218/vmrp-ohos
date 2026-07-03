/*
 * Index.ets - vmrp 鸿蒙主界面。
 *
 * 布局：
 *   - ContentSlot：占位渲染区，native 在其上树时 createNode(ARKUI_NODE_XCOMPONENT) 创建
 *     XComponent 节点并挂入（官方范式5：NDK 节点创建 + OH_ArkUI_SurfaceHolder）。
 *   - 控制按钮：选择 MRP 文件、方向键、数字键、左右软键、确认键。
 *   - 文本编辑弹层：native 请求编辑时显示 TextInput。
 *
 * 渲染：XComponent 节点由 native 侧 EGL 渲染（240x320）。
 * 输入：XComponent 区域触摸由 native NODE_TOUCH_EVENT 回调处理（坐标归一化在 native）；
 *       实体按键/软键盘按钮走 sendKey。
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { NodeContent } from '@kit.ArkUI';
import {
  VmrpEngineTs, VMRP_KEY_PRESS, VMRP_KEY_RELEASE,
  MR_KEY_UP, MR_KEY_DOWN, MR_KEY_LEFT, MR_KEY_RIGHT,
  MR_KEY_SELECT, MR_KEY_SOFTLEFT, MR_KEY_SOFTRIGHT,
  MR_KEY_STAR, MR_KEY_POUND
} from '../vmrp/VmrpEngine';
import { VmrpAssets } from '../vmrp/VmrpAssets';
import { gAbilityContext } from '../entryability/EntryAbility';

// 居中文本编辑对话框。原文本由 controller 的 initialText 传入（回显），
// 确定/取消分别走 submitEdit/cancelEdit 并关闭弹窗。
@CustomDialog
struct EditDialog {
  controller: CustomDialogController;
  @Link editText: string;
  submit: (text: string) => void = () => {};
  cancel: () => void = () => {};

  build() {
    Column() {
      Text('请输入文字')
        .fontSize(16)
        .fontColor(Color.Black)
        .margin({ top: 16, bottom: 10 })
      TextArea({ text: this.editText })
        .onChange((v: string) => { this.editText = v; })
        .width('90%')
        .layoutWeight(1)
        .fontSize(16)
        .fontColor(Color.Black)
      Row() {
        Button('取消')
          .width(100)
          .height(40)
          .onClick(() => {
            this.cancel();
            this.controller.close();
          })
        Button('确定')
          .width(100)
          .height(40)
          .onClick(() => {
            this.submit(this.editText);
            this.controller.close();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .margin({ top: 12, bottom: 16 })
    }
    .width('82%')
    .height(340)
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

@Entry
@Component
struct Index {
  @State status: string = '未启动';
  @State running: boolean = false;
  @State editText: string = '';
  private engine: VmrpEngineTs = new VmrpEngineTs();
  // 当前按住未释放的键，用于长按支持
  private pressedKeys: Set<number> = new Set();
  // ContentSlot 占位容器：native 在 ON_ATTACH_TO_WINDOW 时 createNode(ARKUI_NODE_XCOMPONENT) 挂入。
  // 范式5要求 XComponent 由 NDK 创建，否则 SurfaceHolder_Create 返回 rc=401。
  private nodeContent: NodeContent = new NodeContent();
  // 居中编辑弹窗。alignment: Center 居中显示。
  // autoCancel:false 禁止点遮罩/返回键关闭，强制用户用取消/确定按钮——
  // 按钮内保证 cancel/submit 通知 native，避免非按钮关闭导致 native 死等卡死。
  private editController: CustomDialogController = new CustomDialogController({
    builder: EditDialog({
      editText: this.editText,
      submit: (t: string) => { this.engine.submitEdit(t); },
      cancel: () => { this.engine.cancelEdit(); }
    }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    autoCancel: false
  });

  aboutToAppear(): void {
    this.bootstrap();
  }

  async bootstrap(): Promise<void> {
    try {
      this.status = '正在加载 native 模块...';
      await this.engine.init();
      this.status = 'native 模块已加载';
      // getContext(this) 在 aboutToAppear 早期可能返回 undefined，优先用全局 ability context。
      const ctx = (gAbilityContext ?? getContext(this)) as common.UIAbilityContext;

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

      // 4. 注册编辑回调：native 检测到 MRP 请求编辑时回调此处，携带待编辑的原文本回显到输入框。
      this.engine.setEditCallback((editText: string) => {
        this.editText = editText;
        this.editController.open();
      });

      // 5. 把 ContentSlot 的 NodeContent 传给 native 注册回调。
      //    ContentSlot 上树时 native 会创建 XComponent 节点 + SurfaceHolder + 挂载。
      this.engine.createSurfaceNode(this.nodeContent);

      this.status = '就绪，正在启动默认MRP...';
      // 6. 自动启动默认MRP，解决启动卡开屏问题
      await this.startDefault();
    } catch (e) {
      // ArkTS 对 Error 做 JSON.stringify 会得到 {}，用 message/businessError 更可读。
      const err = e as Error;
      const msg = err?.message ?? String(e);
      this.status = `初始化失败: ${msg}`;
      console.error(`vmrp bootstrap failed: ${msg}`);
    }
  }

  // 直接启动内置 gblmt.mrp（无需文件选择器），用于验证核心运行路径。
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

  // 按键触摸处理器：按下时发送 press，抬起时发送 release，支持长按。
  onKeyTouch(key: number, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (!this.pressedKeys.has(key)) {
        this.pressedKeys.add(key);
        this.engine.sendKey(VMRP_KEY_PRESS, key);
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.pressedKeys.has(key)) {
        this.pressedKeys.delete(key);
        this.engine.sendKey(VMRP_KEY_RELEASE, key);
      }
    }
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

      // 渲染区：ContentSlot 占位，native 在其上树时创建 XComponent 节点（范式5）。
      // XComponent 节点尺寸由 native 设为 240x320，触摸由 native NODE_TOUCH_EVENT 处理。
      // ContentSlot 自身不支持设宽高，用 Stack 容器固定尺寸，ContentSlot 填满。
      Stack() {
        ContentSlot(this.nodeContent)
      }
      .width(240)
      .height(320)
      .backgroundColor(Color.Black)

      // 方向键 + 功能键（onTouch 支持长按）
      Grid() {
        GridItem() { Button('↑').fontSize(20).onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_UP, e)) }
        GridItem() { Button('←').fontSize(20).onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_LEFT, e)) }
        GridItem() { Button('确认').fontSize(14).onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_SELECT, e)) }
        GridItem() { Button('→').fontSize(20).onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_RIGHT, e)) }
        GridItem() { Button('↓').fontSize(20).onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_DOWN, e)) }
        GridItem() { Button('左软').fontSize(14).onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_SOFTLEFT, e)) }
        GridItem() { Button('右软').fontSize(14).onTouch((e: TouchEvent) => this.onKeyTouch(MR_KEY_SOFTRIGHT, e)) }
      }
      .columnsTemplate('1fr 1fr 1fr')
      .width('100%')
      .height(180)
      .padding(4)

      // 数字键（onTouch 支持长按）
      Grid() {
        ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, MR_KEY_STAR, 0, MR_KEY_POUND], (k: number) => {
          GridItem() {
            Button(`${k === MR_KEY_STAR ? '*' : k === MR_KEY_POUND ? '#' : k}`)
              .fontSize(16)
              .onTouch((e: TouchEvent) => this.onKeyTouch(k, e))
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
  }
}
