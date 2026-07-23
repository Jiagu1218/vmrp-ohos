# HarmonyOS 沉浸式布局知识与经验

## 一、核心组件

| 组件 | 来源 | 用途 |
|------|------|------|
| `HdsNavigation` | `@kit.UIDesignKit` | HDS设计规范导航容器，支持动态模糊标题栏 |
| `HdsTabs` | `@kit.UIDesignKit` | HDS设计规范Tabs，支持悬浮页签+沉浸光感 |
| `HdsTabsController` | `@kit.UIDesignKit` | HdsTabs控制器 |
| `hdsMaterial` | `@kit.UIDesignKit` | 沉浸光感材质枚举工具 |
| `BottomTabBarStyle` | 全局 | 底部页签样式，支持SymbolGlyphModifier双态图标 |
| `SymbolGlyphModifier` | `@kit.ArkUI` | 系统图标修饰器，设置颜色/渲染策略 |
| `SymbolRenderingStrategy` | 全局枚举 | 图标渲染策略（MONOLOUR/MULTIPLE_COLOR等） |
| `window` | `@kit.ArkUI` | 窗口管理，获取避让区域 |
| `display` | `@kit.ArkUI` | 显示管理，获取屏幕密度 |

## 二、标题栏渐变模糊（核心机制）

### 2.1 原理

HdsNavigation标题栏支持三种动态模糊样式，随内容滚动实时变化：

| 样式 | 效果 | 适用场景 |
|------|------|----------|
| `COMMON_BLUR` | 均匀模糊，边界清晰 | 列表型非沉浸式 |
| `TRANSITION_BLUR` | 标题内容颜色/状态线性过渡 | 沉浸式图文详情 |
| `GRADIENT_BLUR` | 模糊渐变增强/减弱，边界柔和 | 增强沉浸感（推荐） |

### 2.2 关键配置

```typescript
HdsNavigation() {
  // 内容区
}
.titleBar({
  content: {
    title: { mainTitle: '标题' },
    menu: { value: [...] }
  },
  style: {
    scrollEffectOpts: {
      enableScrollEffect: true,
      scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
      blurEffectiveStartOffset: LengthMetrics.vp(0),
      blurEffectiveEndOffset: LengthMetrics.vp(20),
    },
    originalStyle: {
      backgroundStyle: { backgroundColor: Color.Transparent }
    },
    systemMaterialEffect: {
      materialType: hdsMaterial.MaterialType.ADAPTIVE,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
    },
  },
  enableComponentSafeArea: false,  // ← 关键！
  avoidLayoutSafeArea: true,
})
.bindToScrollable([this.scroller])
```

### 2.3 enableComponentSafeArea 陷阱

这是最关键的配置项，直接决定渐变模糊是否生效：

| 值 | 效果 | 问题 |
|----|------|------|
| `true` | 内容区自动避让标题栏，不被遮挡 | **滚动模糊失效**，标题栏始终不透明 |
| `false` | 内容穿透到标题栏下方 | **滚动模糊生效**，但内容被标题栏遮挡 |

**解决方案**：`enableComponentSafeArea: false` + List顶部手动占位

```typescript
List({ scroller: this.scroller }) {
  ListItem() {
    Column().width('100%').height(this.titleBarOffset)  // 手动占位
  }
  // 正常列表内容...
}
```

### 2.4 originalStyle 必须设置

不设置 `originalStyle: { backgroundStyle: { backgroundColor: Color.Transparent } }` 时，标题栏初始背景不透明，无法看到穿透效果。

## 三、动态计算标题栏占位高度

硬编码占位高度在不同设备上会出错，必须动态计算：

```typescript
@Local titleBarOffset: number = 96;  // 默认值：状态栏48+标题栏48

aboutToAppear(): void {
  const ctx = gAbilityContext;
  if (ctx) {
    try {
      const win: window.Window = ctx.windowStage.getMainWindowSync();
      const topPx: number = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
      const density: number = display.getDefaultDisplaySync().densityPixels;
      this.titleBarOffset = topPx / density + 48;  // 状态栏vp + MINI标题栏48vp
    } catch (_e) {}
  }
}
```

关键点：
- `getWindowAvoidArea(TYPE_SYSTEM).topRect.height` 返回像素值
- `display.getDefaultDisplaySync().densityPixels` 获取屏幕密度
- 除以density转vp，再加MINI标题栏高度48vp
- MINI标题栏高度约48vp，LARGE约112vp

## 四、HdsTabs 悬浮底部导航

### 4.1 基本结构

```typescript
HdsTabs({ controller: this.hdsTabsController }) {
  TabContent() {
    // 游戏库内容
  }
  .tabBar(new BottomTabBarStyle({
    normal: new SymbolGlyphModifier($r('sys.symbol.gamecontroller'))
      .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
      .fontColor([$r('sys.color.ohos_id_color_bottom_tab_icon_off')]),
    selected: new SymbolGlyphModifier($r('sys.symbol.gamecontroller'))
      .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
      .fontColor([$r('app.color.accent_color')])
  }, '游戏库'))

  TabContent() {
    // 收藏内容
  }
  .tabBar(new BottomTabBarStyle({
    normal: ...,
    selected: ...
  }, '收藏'))
}
.barOverlap(true)           // 内容延伸到Tab栏下方
.vertical(false)
.barPosition(BarPosition.End)
.scrollable(false)
.animationDuration(0)
.clip(false)                // 允许内容穿透裁剪
.barFloatingStyle({
  barBottomMargin: 28,
  systemMaterialEffect: {
    materialType: hdsMaterial.MaterialType.ADAPTIVE,
    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
  }
})
```

### 4.2 关键属性

| 属性 | 值 | 说明 |
|------|-----|------|
| `barOverlap` | `true` | 内容延伸到Tab栏下方，Tab浮在内容上 |
| `clip` | `false` | 不裁剪超出HdsTabs区域的内容 |
| `barFloatingStyle.barBottomMargin` | `28` | Tab栏距屏幕底部距离(vp) |
| `barFloatingStyle.systemMaterialEffect` | ADAPTIVE/ADAPTIVE | 系统自适应沉浸光感材质 |
| `scrollable` | `false` | 禁止滑动切换Tab |
| `animationDuration` | `0` | Tab切换无动画（更流畅） |

### 4.3 BottomTabBarStyle 图标

`BottomTabBarStyle` 构造函数接受两个参数：
1. `{ normal: SymbolGlyphModifier, selected: SymbolGlyphModifier }` — 双态图标
2. `string` — 标签文字

系统颜色资源：
- 未选中图标：`$r('sys.color.ohos_id_color_bottom_tab_icon_off')`
- 选中图标：自定义accent色

`SymbolRenderingStrategy.MULTIPLE_COLOR` 支持多色图标渲染。

### 4.4 底部避让

`barOverlap(true)` 时Tab栏浮在内容上，内容需要底部padding避让：

```typescript
List()
  .padding({ left: 0, right: 0, top: 4, bottom: 84 })
```

计算：Tab栏高度约56vp + barBottomMargin 28vp = 84vp

## 五、内容穿透 checklist

要让滚动模糊效果正常工作，以下条件必须全部满足：

1. **`enableComponentSafeArea: false`** — 内容穿透标题栏
2. **`avoidLayoutSafeArea: true`** — 标题栏仍避让状态栏
3. **`originalStyle.backgroundStyle.backgroundColor: Color.Transparent`** — 标题栏初始透明
4. **`scrollEffectOpts.enableScrollEffect: true`** — 启用滚动效果
5. **`bindToScrollable([scroller])`** — 绑定滚动器
6. **List `.clip(false)`** — 允许内容超出裁剪区域
7. **List顶部手动占位** — 防止内容被标题栏遮挡
8. **HdsTabs `.clip(false)`** — 允许内容穿透HdsTabs边界

## 六、AlphabetIndexer 集成

### 6.1 按名称排序时显示

```typescript
if (this.sortMode === 1 && this.flatItems.length > 0 && this.searchQuery.length === 0) {
  AlphabetIndexer({ arrayValue: this.indexArray, selected: this.selectedIndex })
    .color($r('app.color.settings_desc_color'))
    .selectedColor($r('app.color.accent_color'))
    .selectedBackgroundColor($r('app.color.settings_card_bg'))
    .usingPopup(false)
    .font({ size: 10 })
    .selectedFont({ size: 12, weight: FontWeight.Bold })
    .itemSize(24)
    .alignStyle(IndexerAlign.Left)
    .popupPosition({ x: -72, y: this.titleBarOffset })
    .width(24)
    .height('100%')
    .margin({ right: 4 })
    .onSelect((index: number) => {
      const letter = this.indexArray[index];
      const flatIdx = this.flatItems.findIndex((fi: FlatItem) =>
        fi.type === 'header' && fi.letter === letter);
      if (flatIdx >= 0) {
        this.listScroller.scrollToIndex(flatIdx + offset, false, ScrollAlign.CENTER);
      }
    })
}
```

### 6.2 popupPosition 偏移

`popupPosition` 的 `y` 值必须设为 `this.titleBarOffset`，否则冒泡会跑到状态栏里。

### 6.3 冒泡背景灰色问题

API 23下 `popupBackground` 默认值为 `#66808080`（半透明灰色），设置 `popupBackgroundBlurStyle` 后仍会被灰色覆盖。**暂无解决方案**，等 API 26 沉浸式材质默认支持后可解决。当前临时方案：`usingPopup(false)` 关闭冒泡。

### 6.4 onScrollIndex 联动

```typescript
.onScrollIndex((start: number) => {
  const offset = 1 + (this.searchMode ? 1 : 0);  // 1=占位ListItem
  const idx = start - offset;
  if (idx < 0 || idx >= this.flatItems.length) return;
  const item = this.flatItems[idx];
  if (item.type === 'header') {
    const ai = this.indexArray.indexOf(item.letter);
    if (ai >= 0) this.selectedIndex = ai;
  } else if (item.type === 'card') {
    for (let i = idx; i >= 0; i--) {
      if (this.flatItems[i].type === 'header') {
        const ai = this.indexArray.indexOf(this.flatItems[i].letter);
        if (ai >= 0) this.selectedIndex = ai;
        break;
      }
    }
  }
})
```

offset计算：
- 占位ListItem = 1
- 搜索框ListItem = 1（搜索模式时）
- 总offset = 1 + (searchMode ? 1 : 0)

## 七、HdsNavigation 嵌套 HdsTabs 的布局层级

```
HdsNavigation
  ├── 标题栏（系统自动渲染，避让状态栏）
  │   ├── systemMaterialEffect（沉浸光感按钮）
  │   └── scrollEffectOpts（渐变模糊）
  └── HdsTabs
      ├── TabContent[0]（游戏库）
      │   └── Stack
      │       ├── Refresh → List（含顶部占位+底部padding）
      │       └── AlphabetIndexer（按名称排序时）
      ├── TabContent[1]（收藏）
      │   └── Stack
      │       ├── Refresh → List
      │       └── AlphabetIndexer
      └── barFloatingStyle（悬浮Tab栏，沉浸光感材质）
```

## 八、常见问题与解决方案

### Q1: 标题栏始终不透明，没有模糊效果
- 检查 `enableComponentSafeArea` 是否为 `false`
- 检查 `originalStyle.backgroundStyle.backgroundColor` 是否为 `Color.Transparent`
- 检查 `bindToScrollable` 是否绑定了正确的 Scroller
- 检查 List 是否设了 `.clip(false)`

### Q2: 内容被标题栏遮挡
- `enableComponentSafeArea: false` 后必须手动添加顶部占位
- 占位高度通过 `window.getWindowAvoidArea` 动态计算

### Q3: 标题栏入侵状态栏
- `avoidLayoutSafeArea: true` 让标题栏避让状态栏
- `avoidLayoutSafeArea: false` 时标题栏会延伸到状态栏区域

### Q4: 列表最后一项被Tab栏遮挡
- `barOverlap(true)` 时Tab栏浮在内容上
- List需要 `padding({ bottom: 84 })` 避让（Tab栏56vp + margin28vp）

### Q5: HdsTabs包裹后标题栏模糊消失
- HdsTabs默认 `clip(true)` 截断内容
- 设置 `.clip(false)` 让内容穿透

### Q6: AlphabetIndexer冒泡跑到状态栏
- `popupPosition({ y: this.titleBarOffset })` 向下偏移

### Q7: 冒泡背景灰色，无法实现光感
- API 23的 `popupBackground` 默认 `#66808080` 覆盖模糊材质
- 显式设 `popupBackground('#00000000')` 无效
- API 26后默认支持沉浸式材质，届时可解决
- 临时方案：`usingPopup(false)` 关闭冒泡

### Q8: 收藏页Repeat只显示名称不显示卡片
- Repeat必须设置 `.templateId()` 路由到正确的template
- 否则所有项走 `.each()` 默认builder
- 收藏页只有card类型：`.templateId(() => 'card')`
- 游戏库有header+card：`.templateId((item) => item.type)`

## 九、参考文档

- [沉浸光感](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/immersive-light-sense-V5)
- [设置动态模糊样式](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/hds-navigation-dynamic-blur-V5)
- [HdsTabs组件](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/hdstabs-V5)
- [AlphabetIndexer](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/ts-container-alphabet-indexer-V5)
- [NEXT Player 沉浸光感实战](https://developer.huawei.com/consumer/cn/forum/home)
