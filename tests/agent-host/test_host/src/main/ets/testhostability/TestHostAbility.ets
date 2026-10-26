import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';

export default class TestHostAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    // This ability intentionally has no window content. It only supplies an
    // application process in which device-side integration tests can load HAR.
  }
}

