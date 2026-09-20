#!/bin/sh
# 运行 wg_tunnel 本地单元测试（Hypium LocalUnit，免设备）
#
# 被测对象：wg_tunnel/src/main/ets/keepalive/SingleFlightLoop.ets（真实源文件）
# 用例位置：wg_tunnel/src/test/（注册于 List.test.ets）
# 依赖处理：@ohos.hilog 经 wg_tunnel/src/mock/mock-config.json5 在测试构建期替换
#
# 用法（工作目录任意）：
#   sh platform-harmonyos/tests/run-local-unit-test.sh
#
# 说明：hvigor test 在用例失败时退出码仍可能为 0，因此以结果文件判定成败。
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)   # platform-harmonyos 工程根
cd "$PROJECT_ROOT"

DEVECO_SDK_HOME="C:\Program Files\Huawei\DevEco Studio\sdk"
export DEVECO_SDK_HOME
"/c/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.bat" test -p module=wg_tunnel -p coverage=false

RESULT="$PROJECT_ROOT/wg_tunnel/.test/default/intermediates/test/coverage_data/test_result.txt"
SUMMARY=$(grep -E "^Tests run:" "$RESULT" | tail -1)
echo "LocalUnit 结果: $SUMMARY"
echo "$SUMMARY" | grep -qE "Failure: 0, Error: 0"
