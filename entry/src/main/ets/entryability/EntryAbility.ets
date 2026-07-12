/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, AppStorageV2 } from '@kit.ArkUI';
import { AvoidData } from '../common/AvoidData';
import { VmrpEngineTs } from '../vmrp/VmrpEngine';

const DOMAIN = 0x0000;

// 全局 ability context：供 Index 页面在 aboutToAppear 早期取用。
// getContext(this) 在组件挂载早期可能返回 undefined，用全局变量更稳妥。
export let gAbilityContext: common.UIAbilityContext | null = null;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    gAbilityContext = this.context;
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      try {
        const win = windowStage.getMainWindowSync();
        win.setWindowLayoutFullScreen(true);
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          statusBarContentColor: '#FFFFFF',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#FFFFFF'
        });
        const avoid: AvoidData = AppStorageV2.connect(AvoidData, 'avoidData', () => new AvoidData())!;
        const uiCtx = win.getUIContext();
        const sysAvoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        avoid.topVp = uiCtx.px2vp(sysAvoid.topRect.height);
        const navAvoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        avoid.bottomVp = uiCtx.px2vp(navAvoid.bottomRect.height);
        win.on('avoidAreaChange', (data) => {
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
            avoid.topVp = uiCtx.px2vp(data.area.topRect.height);
          } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
            avoid.bottomVp = uiCtx.px2vp(data.area.bottomRect.height);
          }
        });
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'Failed to set immersive. Cause: %{public}s', JSON.stringify(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    const engine = new VmrpEngineTs();
    if (engine.isRunning()) {
      engine.mediaResume();
    }
  }

  onBackground(): void {
    // Ability has back to background — 暂停音频避免后台继续播放
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    const engine = new VmrpEngineTs();
    if (engine.isRunning()) {
      engine.mediaPause();
    }
  }
}