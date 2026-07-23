import { KeyCode } from '@kit.InputKit';

export const STICK_DEADZONE = 0.3;

export function keyCodeToSrc(keyCode: number): string {
  if (keyCode === KeyCode.KEYCODE_DPAD_UP) return 'dpad_up';
  if (keyCode === KeyCode.KEYCODE_DPAD_DOWN) return 'dpad_down';
  if (keyCode === KeyCode.KEYCODE_DPAD_LEFT) return 'dpad_left';
  if (keyCode === KeyCode.KEYCODE_DPAD_RIGHT) return 'dpad_right';
  if (keyCode === KeyCode.KEYCODE_DPAD_CENTER) return 'btn_a';
  if (keyCode === KeyCode.KEYCODE_BUTTON_A) return 'btn_a';
  if (keyCode === KeyCode.KEYCODE_BUTTON_B) return 'btn_b';
  if (keyCode === KeyCode.KEYCODE_BUTTON_X) return 'btn_x';
  if (keyCode === KeyCode.KEYCODE_BUTTON_Y) return 'btn_y';
  if (keyCode === KeyCode.KEYCODE_BUTTON_L1) return 'btn_l1';
  if (keyCode === KeyCode.KEYCODE_BUTTON_R1) return 'btn_r1';
  if (keyCode === KeyCode.KEYCODE_BUTTON_START) return 'btn_start';
  if (keyCode === KeyCode.KEYCODE_BUTTON_SELECT) return 'btn_select';
  return '';
}

export function axisToStickSrc(axis: AxisModel, direction: string): string {
  const prefix = (axis === AxisModel.ABS_X || axis === AxisModel.ABS_Y) ? 'stick_l' :
    (axis === AxisModel.ABS_HAT0X || axis === AxisModel.ABS_HAT0Y) ? 'dpad' : 'stick_r';
  return `${prefix}_${direction}`;
}

export function computeStickDirections(x: number, y: number): string[] {
  const dirs: string[] = [];
  if (x > STICK_DEADZONE && y < -STICK_DEADZONE) dirs.push('up_right');
  else if (x > STICK_DEADZONE && y > STICK_DEADZONE) dirs.push('down_right');
  else if (x < -STICK_DEADZONE && y > STICK_DEADZONE) dirs.push('down_left');
  else if (x < -STICK_DEADZONE && y < -STICK_DEADZONE) dirs.push('up_left');
  else {
    if (y < -STICK_DEADZONE) dirs.push('up');
    if (y > STICK_DEADZONE) dirs.push('down');
    if (x < -STICK_DEADZONE) dirs.push('left');
    if (x > STICK_DEADZONE) dirs.push('right');
  }
  return dirs;
}
