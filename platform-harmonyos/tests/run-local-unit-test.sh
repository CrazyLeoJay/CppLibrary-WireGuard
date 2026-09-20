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
# 输出结构：
#   1. 各用例结果表（test= / result=）
#   2. 行为明细——每个用例的标题/参数/流程/实测值/逐条断言（runner日志提取）
#   3. 汇总（Tests run / Failure / Error）
#   4. 失败时：打印失败原因块（含断言 message 与出错位置）
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
RUNLOG="$PROJECT_ROOT/wg_tunnel/.test/default/intermediates/test/coverage_data/coverage.log"

echo ""
echo "==================== LocalUnit 各用例结果 ===================="
awk '/^test=/{name=substr($0,6)} /^result=/{printf "  %-58s %s\n", name, substr($0,8)}' "$RESULT"

echo ""
echo "==================== 行为明细（测什么/流程/实测/断言） ===================="
if [ -f "$RUNLOG" ]; then
  sed 's/.*JSAPP: //' "$RUNLOG" | grep -E "^\[T[0-9]+\]" || true
fi

SUMMARY=$(grep -E "^Tests run:" "$RESULT" | tail -1)
echo ""
echo "==================== 汇总: $SUMMARY ===================="

if echo "$SUMMARY" | grep -qE "Failure: 0, Error: 0"; then
  exit 0
fi

echo ""
echo "==================== 失败原因 ===================="
# 失败块格式：message: <断言message>, Error in <用例>, expect X equals Y + 堆栈
grep -A4 -E "^(message: |Error in )" "$RESULT" | head -60 || true
exit 1
