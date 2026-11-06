#!/usr/bin/env python3
"""Install this user's persistent CLI adapter; no notebook writes or new tunnel.

Credentials live in owner-only Application Support files. The existing tunnel
runtime key is entered locally with getpass and never crosses chat or argv.
"""
import json, os, pathlib, plistlib, secrets, shutil, subprocess

SOURCE = pathlib.Path(__file__).resolve().parent
HOME = pathlib.Path.home()
RUNTIME = HOME / 'Library/Application Support/Lingrove MCP'
AGENTS = HOME / 'Library/LaunchAgents'
TUNNEL = 'tunnel_6ae9409950588191856c7ca324f7d222'

def agent(name, args, env=None):
    return {'Label':name,'ProgramArguments':args,'EnvironmentVariables':env or {},
            'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':15,
            'StandardOutPath':str(RUNTIME/(name+'.log')),
            'StandardErrorPath':str(RUNTIME/(name+'.error.log'))}

def main():
    os.umask(0o077)
    RUNTIME.mkdir(parents=True,exist_ok=True,mode=0o700)
    RUNTIME.chmod(0o700)
    AGENTS.mkdir(exist_ok=True)
    for name in ('bridge.mjs','draft-store.mjs','write-policy.mjs','server.mjs','package.json','package-lock.json','connect.py','tunnel.py'):
        shutil.copy2(SOURCE/name,RUNTIME/name)
    shutil.copy2(SOURCE.parents[1]/'skills/lingrove-cli/references/semantic-modeling.md',RUNTIME/'semantic-modeling.md')
    subprocess.run(['npm','ci','--ignore-scripts','--omit=dev'],cwd=RUNTIME,check=True)
    app = str((HOME/'.local/bin/lingrove-dev').resolve().parents[2])
    cli = str((HOME/'.local/bin/lingrove-dev').resolve())
    config_path=RUNTIME/'config.json'
    if not config_path.exists():
        config_path.write_text(json.dumps({'cli':cli,'app':app,'state':str(RUNTIME/'drafts'),'port':19681,'bearer':secrets.token_urlsafe(48)},indent=2)+'\n')
    config=json.loads(config_path.read_text())
    config['guidePath']=str(RUNTIME/'semantic-modeling.md')
    config_path.write_text(json.dumps(config,indent=2)+'\n')
    (RUNTIME/'mcp-authorization').write_text('Bearer '+config['bearer'])
    # Reuse the already verified official release binary without depending on build output.
    binary=HOME/'lingrove/build/private-mcp-preparation/tunnel-client/tunnel-client'
    shutil.copy2(binary,RUNTIME/'tunnel-client')
    (RUNTIME/'tunnel.yaml').write_text('''config_version: 1
control_plane:
  base_url: "https://api.openai.com"
  tunnel_id: "'''+TUNNEL+'''"
  api_key: "file:'''+str(RUNTIME/'runtime-key')+'''"
health:
  listen_addr: "127.0.0.1:0"
admin_ui:
  open_browser: false
log:
  level: info
  format: json
mcp:
  server_urls:
    - channel: main
      url: "http://127.0.0.1:19681/mcp"
  extra_headers:
    Authorization: "file:'''+str(RUNTIME/'mcp-authorization')+'''"
  discovery_extra_headers:
    Authorization: "file:'''+str(RUNTIME/'mcp-authorization')+'''"
''')
    definitions={
        'io.lingrove.mcp':agent('io.lingrove.mcp',[shutil.which('node'),str(RUNTIME/'server.mjs')],{'LINGROVE_MCP_CONFIG':str(config_path)}),
        'io.lingrove.mcp-tunnel':agent('io.lingrove.mcp-tunnel',['/usr/bin/python3',str(RUNTIME/'tunnel.py')])}
    for label,value in definitions.items():
        (AGENTS/(label+'.plist')).write_bytes(plistlib.dumps(value))
    command=RUNTIME/'Connect Lingrove.command'
    command.write_text('#!/bin/zsh -f\nexec /usr/bin/python3 '+"'"+str(RUNTIME/'connect.py')+"'"+'\n')
    command.chmod(0o700)
    target='gui/'+str(os.getuid())
    if subprocess.run(['launchctl','print',target+'/io.lingrove.mcp'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
        subprocess.run(['launchctl','bootstrap',target,str(AGENTS/'io.lingrove.mcp.plist')],check=True)
    else:
        subprocess.run(['launchctl','kickstart','-k',target+'/io.lingrove.mcp'],check=True)
    print('Local MCP installed. Refresh ChatGPT tools.' if (RUNTIME/'runtime-key').exists() else
          'Local MCP installed. Enter the existing Tunnel runtime key through Connect Lingrove.command to enable the tunnel.')

if __name__=='__main__': main()
