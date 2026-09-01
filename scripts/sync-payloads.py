#!/usr/bin/env python3
"""Re-incrusta provision/src/* en los heredocs __PAYLOAD_*__ de build-omarchy-arm.sh."""
import sys, os
RAIZ="/Users/gabriel/Development/2026/omarchy_ai"
MAPA={
 "__PAYLOAD_PROVISION_STAGE1_SH__":"provision/src/stage1.sh",
 "__PAYLOAD_PROVISION_STAGE2_SH__":"provision/src/stage2.sh",
 "__PAYLOAD_PROVISION_STAGE3_SH__":"provision/src/stage3.sh",
 "__PAYLOAD_PROVISION_REPAIR_SH__":"provision/src/repair.sh",
 "__PAYLOAD_PROVISION_SANITIZE_SH__":"provision/src/sanitize.sh",
 "__PAYLOAD_PROVISION_EXTRAS_SH__":"provision/src/omarchy-arm-extras",
 "__PAYLOAD_PROVISION_CLIPBRD_SH__":"provision/src/omarchy-arm-clipboard",
 "__PAYLOAD_PROVISION_VDAGENT_PY__":"provision/src/omarchy-arm-vdagent",
 "__PAYLOAD_PROVISION_SHARE_SH__":"provision/src/omarchy-arm-share",
 "__PAYLOAD_PROVISION_USUARIO_SH__":"provision/src/omarchy-arm-usuario",
 "__PAYLOAD_LEEME_MD__":"provision/src/README.md",
 "__PAYLOAD_PROVISION_ARMSYNC_SH__":"provision/src/hooks/10-arm-sync",
 "__PAYLOAD_SCRIPTS_BUILD_EXP__":"scripts/build.exp",
 "__PAYLOAD_SCRIPTS_REPAIR_EXP__":"scripts/repair.exp",
 "__PAYLOAD_SCRIPTS_MAKE-UTM_SH__":"scripts/make-utm.sh",

}
p=os.path.join(RAIZ,"build-omarchy-arm.sh")
lineas=open(p).read().split("\n")
cambios=0
for marca,rel in MAPA.items():
    ini=next((i for i,l in enumerate(lineas) if l.rstrip().endswith("<<'%s'"%marca)), None)
    if ini is None: print(f"  !! sin apertura: {marca}"); continue
    fin=next(j for j in range(ini+1,len(lineas)) if lineas[j]==marca)
    nuevo=open(os.path.join(RAIZ,rel)).read().rstrip("\n").split("\n")
    if lineas[ini+1:fin]==nuevo: continue
    lineas[ini+1:fin]=nuevo
    cambios+=1
    print(f"  re-incrustado {os.path.basename(rel)} ({len(nuevo)} lineas)")
open(p,"w").write("\n".join(lineas))
print(f"  {cambios} payload(s) actualizados" if cambios else "  todo ya estaba sincronizado")

# Un payload sin entrada en MAPA es un fichero que nadie vuelve a sincronizar:
# se edita la fuente, no pasa nada, y el constructor sigue desplegando lo viejo.
import re
todas=set(re.findall(r"<<'(__PAYLOAD_[A-Z0-9_.-]+__)'", "\n".join(lineas)))
huerfanas=sorted(todas - set(MAPA))
if huerfanas:
    print("  sin fuente declarada (su fuente de verdad es el propio payload):")
    for h in huerfanas: print(f"    {h}")
