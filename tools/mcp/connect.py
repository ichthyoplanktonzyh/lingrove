#!/usr/bin/env python3
"""Local secure-input final connection step, reusable after a key rotation."""
import getpass, os, pathlib, subprocess

def main():
    os.umask(0o077)
    root=pathlib.Path(__file__).resolve().parent
    path=root/'runtime-key'
    if not path.exists():
        key=getpass.getpass('粘贴现有 OpenAI Tunnel 专用运行密钥（不回显，不发送到聊天）: ').strip()
        if not key: raise SystemExit('没有输入密钥；未启动 Tunnel。')
        path.write_text(key)
        path.chmod(0o600)
    key=path.read_text().strip()
    command=[str(root/'tunnel-client'),'doctor','--config',str(root/'tunnel.yaml'),'--json']
    result=subprocess.run(command,capture_output=True,text=True)
    output=(result.stdout+result.stderr).replace(key,'[redacted]')
    (root/'doctor.log').write_text(output)
    if result.returncode:
        print('连接预检失败，已保留配置。请让 Codex 检查脱敏 doctor.log；不要发送密钥。')
        raise SystemExit(result.returncode)
    label='io.lingrove.mcp-tunnel'
    target='gui/'+str(os.getuid())
    plist=pathlib.Path.home()/'Library/LaunchAgents'/ (label+'.plist')
    if subprocess.run(['launchctl','print',target+'/'+label],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
        subprocess.run(['launchctl','bootstrap',target,str(plist)],check=True)
    else:
        subprocess.run(['launchctl','kickstart','-k',target+'/'+label],check=True)
    print('Lingrove Tunnel 已启动并设置登录后自动启动。可以回到 Codex 验证并刷新工具。')

if __name__=='__main__': main()
