# HdsNavigation / HdsNavDestination 沉浸光感避让实战指南

## 目标效果

- 标题栏背景延伸到状态栏区域（沉浸式光感模糊）
- 标题栏文字/返回按钮**不入侵**状态栏
- 内容底部**避开**导航条（小艺导航条）
- 滚动时标题栏渐变模糊（从透明到毛玻璃）

## 核心配置（一行关键代码）

在 `.titleBar()` 中设置 `avoidLayoutSafeArea: true`：

```typescript
HdsNavDestination() {
  List({ scroller: this.listScroller }) {
    // ...
  }
  .clip(false)
  .cachedCount(2, true)
  .expandSafeArea()
  .padding({ bottom: this.avoidData.bottomVp })
}
.titleBar({
  content: {
    title: { mainTitle: '设置' },
  },
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
  enableComponentSafeArea: true,   // 内容区自动避让标题栏
  avoidLayoutSafeArea: true,       // ★ 关键：标题栏主动避让状态栏
})
.bindToScrollable([this.listScroller])
```

## 属性说明

| 属性 | 位置 | 值 | 作用 |
|------|------|------|------|
| `avoidLayoutSafeArea` | titleBar() 参数 | `true` | **标题栏主动避让安全区**，文字/按钮不入侵状态栏 |
| `enableComponentSafeArea` | titleBar() 参数 | `true` | 标题栏声明为组件级安全区，内容区自动避让标题栏 |
| `scrollEffectOpts` | titleBar style | `GRADIENT_BLUR` | 滚动时标题栏渐变模糊效果 |
| `systemMaterialEffect` | titleBar style | `ADAPTIVE/ADAPTIVE` | 系统自适应沉浸光感材质 |
| `.clip(false)` | List | — | 允许内容绘制延伸到标题栏背后（模糊有东西可糊） |
| `.cachedCount(2, true)` | List | — | 缓存项参与渲染，标题栏背后有真实内容 |
| `.expandSafeArea()` | List | 无参默认 | List 绘制延伸到标题栏背后 |

## 底部导航条避让

List 底部 padding 设为导航条高度：

```typescript
List()
  .padding({ bottom: this.avoidData.bottomVp })
```

`avoidData.bottomVp` 通过 `window.getWindowAvoidArea(AvoidAreaType.TYPE_NAVIGATION_INDICATOR)` 动态获取。

## 踩坑记录

### ❌ 标题栏入侵状态栏

**原因**：`avoidLayoutSafeArea` 默认为 `false`，标题栏不避让安全区，布局从屏幕 y=0 开始。

**解决**：`.titleBar({ avoidLayoutSafeArea: true })`

### ❌ 标题栏有光感但内容被遮挡

**原因**：缺少 `enableComponentSafeArea: true`，内容区不知道标题栏占了多高。

**解决**：`.titleBar({ enableComponentSafeArea: true })`

### ❌ 光感模糊没有内容可糊（标题栏背后空白）

**原因**：List 默认 `clip(true)` 裁掉超出布局区域的绘制，且 `cachedCount` 的 `show` 参数默认 `false`。

**解决**：三件套 `clip(false)` + `cachedCount(2, true)` + `expandSafeArea()`

### ❌ 用 Blank().height(100) 占位

**问题**：魔法值 hack，不同设备标题栏高度不同。

**解决**：用 `enableComponentSafeArea: true` 代替，容器自动告知内容区标题栏高度。

### ❌ 在 HdsNavDestination 上设 ignoreLayoutSafeArea

**问题**：`ignoreLayoutSafeArea([SYSTEM], [TOP])` 会让整个容器布局延伸到状态栏，标题栏文字入侵。

**注意**：`ignoreLayoutSafeArea` 控制的是容器布局范围，不是标题栏避让。避让标题栏用 `titleBar` 的 `avoidLayoutSafeArea`。

## 窗口初始化（EntryAbility）

沉浸式窗口需在 Ability 中设置：

```typescript
const win = windowStage.getMainWindowSync();
win.setWindowLayoutFullScreen(true);
win.setWindowSystemBarProperties({
  statusBarColor: '#00000000',
  statusBarContentColor: '#FFFFFF',
  navigationBarColor: '#00000000',
  navigationBarContentColor: '#FFFFFF'
});
```

## 父页面 HdsNavigation 配置

主页面（无标题栏）不需要 `avoidLayoutSafeArea`，但需注意不要加 `ignoreLayoutSafeArea`，否则会影响子页面：

```typescript
HdsNavigation(this.navPathStack) {
  // 内容
}
.hideTitleBar(true)
.mode(NavigationMode.Stack)
// 不要加 .ignoreLayoutSafeArea() — 会导致子页面标题栏入侵
```

## 完整最小示例

```typescript
import { HdsNavDestination, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { LengthMetrics, AppStorageV2 } from '@kit.ArkUI';
import { AvoidData } from '../common/AvoidData';

@ComponentV2
struct SettingsPage {
  @Local navPathStack: NavPathStack = new NavPathStack();
  private listScroller: Scroller = new Scroller();
  private avoidData: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;

  build() {
    HdsNavDestination() {
      List({ space: 8, scroller: this.listScroller }) {
        ForEach([1, 2, 3, 4, 5], (item: number) => {
          ListItem() {
            Text(`Item ${item}`)
              .width('100%')
              .height(60)
          }
        }, (item: number) => item.toString())
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ bottom: this.avoidData.bottomVp })
      .clip(false)
      .cachedCount(2, true)
      .expandSafeArea()
    }
    .titleBar({
      content: {
        title: { mainTitle: '设置' },
      },
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
      avoidLayoutSafeArea: true,
    })
    .bindToScrollable([this.listScroller])
    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
    })
  }
}
```
