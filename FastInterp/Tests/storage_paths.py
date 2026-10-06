"""Compile and run the actual storage parser with controlled frontend paths.

Only validates data-directory routing, never game startup or plugin execution.
"""
import argparse,json,os,pathlib,subprocess,sys,tempfile
p=argparse.ArgumentParser()
p.add_argument('--source',required=True)
p.add_argument('--compiler',required=True)
p.add_argument('--output',required=True)
a=p.parse_args()
os.environ['PATH']=str(pathlib.Path(a.compiler).resolve().parent)+os.pathsep+os.environ.get('PATH','')
source=pathlib.Path(a.source).read_text()
start=source.index('static void ParseStorageOptions(void)')
brace=source.index('{',start);depth=1;end=brace+1
while depth:
    depth+=(source[end]=='{')-(source[end]=='}');end+=1
function=source[start:end]
prefix=r'''
#include <string>
#include <iostream>
#include <stdexcept>
enum { Frontend=0 };
template <typename... T> void discard_log(T&&...) {}
#define LOG_INFO(...) discard_log(__VA_ARGS__)
#define LOG_ERROR(...) discard_log(__VA_ARGS__)
namespace Settings { struct { bool use_virtual_sd; } values; }
namespace config { constexpr auto enabled="enabled"; namespace storage {
constexpr auto use_virtual_sd="sd"; [[maybe_unused]] constexpr auto use_libretro_save_path="location";
} }
std::string save_dir,system_dir,location,result,created;
bool create_ok=true;
namespace LibRetro {
std::string FetchVariable(const char* key,const char* fallback) {
return std::string(key)=="location" ? location : fallback;
}
std::string GetSaveDir() {return save_dir;}
std::string GetSystemDir() {return system_dir;}
}
namespace FileUtil {
enum class UserPath {UserDir};
bool CreateDir(const std::string& p) {created=p;return create_ok;}
void SetUserPath(const std::string& p) {result=p;}
std::string GetUserPath(UserPath) {return result;}
}
'''
suffix=r'''
int main() {
unsigned count=0;
for (const auto& option : {"LibRetro Default","Azahar Default"}) {
for (const auto& root : {"/container/Documents","/container/Documents/","/container/Documents/3DS","/container/Documents/3ds/"}) {
location=option;save_dir=root;system_dir="/system";result.clear();created.clear();create_ok=true;
ParseStorageOptions();
#ifdef IOS
std::string expected=root;
if (!expected.ends_with("/")) expected+="/";
if (!expected.ends_with("3DS/") && !expected.ends_with("3ds/")) expected+="3DS/";
#else
std::string expected;
if (location=="LibRetro Default") {
expected=root;if (!expected.ends_with("/"))expected+="/";expected+="Azahar/";
}
#endif
if (result!=expected) {
std::cerr<<"Path mismatch: "<<option<<" "<<root<<" -> "<<result<<" expected "<<expected<<"\n";
return 1;
}
++count;
}}
location="LibRetro Default";save_dir="";system_dir="/system";result.clear();create_ok=true;
ParseStorageOptions();
#ifdef IOS
if (result!="/system/3DS/")return 2;
#else
if (result!="/system/Azahar/")return 2;
#endif
++count;
save_dir="/container/Documents";result.clear();create_ok=false;ParseStorageOptions();
if (!result.empty())return 3;
++count;
std::cout<<count<<" actual storage-parser cases passed\n";
}
'''
results=[]
with tempfile.TemporaryDirectory(prefix='manic-storage-') as d:
    tmp=pathlib.Path(d);cpp=tmp/'storage.cpp';cpp.write_text(prefix+function+suffix)
    for platform in ['ios','non-ios']:
        exe=tmp/(platform+'.exe')
        cmd=[a.compiler,'-std=c++20','-Wall','-Wextra','-Werror',str(cpp),'-o',str(exe)]
        if sys.platform=='darwin':
            sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
            cmd[1:1]=['-isysroot',sdk]
        if platform=='ios':cmd.insert(1,'-DIOS')
        compile_result=subprocess.run(cmd,capture_output=True,text=True)
        row={'platform':platform,'compiled':compile_result.returncode==0,'compiler_exit_code':compile_result.returncode}
        if row['compiled']:
            run=subprocess.run([str(exe)],capture_output=True,text=True)
            row.update(passed=run.returncode==0,exit_code=run.returncode,output=run.stdout+run.stderr)
        else:row.update(passed=False,output=compile_result.stderr)
        results.append(row)
report={'coverage':'Actual ParseStorageOptions function with mocked frontend/filesystem; not game or Apple execution','source':str(pathlib.Path(a.source).resolve()),'results':results}
pathlib.Path(a.output).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
