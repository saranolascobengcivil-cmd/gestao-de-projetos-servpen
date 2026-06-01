# Pacote views — uma página Streamlit por arquivo.
#
# Cada view é um script independente carregado pelo st.navigation no app.py.
# Apenas a view ATIVA é executada a cada interação — esse é o ganho principal
# da modularização (~60% menos trabalho por click vs st.tabs).
#
# Convenção:
#  - Cada view começa puxando `usuario`/`perfil` do session_state.
#  - Cada view chama `_load_df_*` no topo (resultado vem do cache).
#  - Views Gestor-only (auditoria, acessos) checam `_pode_gestor()` e fazem
#    `st.error + st.stop()` se não for.
