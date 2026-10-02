import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function withCors(resp: Response) {
  resp.headers.set("Access-Control-Allow-Origin", "*");
  resp.headers.set("Access-Control-Allow-Headers", "authorization, x-client-info, apikey, content-type");
  resp.headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  return resp;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return withCors(new Response("ok"));
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";

    // Cliente no contexto de quem está chamando (respeita RLS normalmente)
    const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return withCors(new Response(JSON.stringify({ error: "Não autenticado" }), { status: 401 }));
    }

    const { data: callerProfile, error: profErr } = await callerClient
      .from("profiles")
      .select("role")
      .eq("id", userData.user.id)
      .single();

    if (profErr || !callerProfile || callerProfile.role !== "bi") {
      return withCors(new Response(JSON.stringify({ error: "Acesso negado: apenas o papel BI pode cadastrar usuários" }), { status: 403 }));
    }

    const body = await req.json().catch(() => ({}));
    const { email, role, vendedor_nome, loja, full_name } = body ?? {};

    if (!email || !role) {
      return withCors(new Response(JSON.stringify({ error: "email e role são obrigatórios" }), { status: 400 }));
    }
    if (!["diretoria", "gerencia", "vendedor", "bi"].includes(role)) {
      return withCors(new Response(JSON.stringify({ error: "role inválida" }), { status: 400 }));
    }

    // Cliente admin (service role) — a chave nunca sai do servidor
    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: invited, error: inviteErr } = await adminClient.auth.admin.inviteUserByEmail(email);
    if (inviteErr || !invited?.user) {
      return withCors(new Response(JSON.stringify({ error: inviteErr?.message || "Falha ao convidar usuário" }), { status: 400 }));
    }

    // O trigger on_auth_user_created já criou um profile padrão (vendedor, inativo).
    // Agora atualizamos com os dados corretos vindos do formulário do BI.
    const { error: updateErr } = await adminClient
      .from("profiles")
      .update({
        role,
        vendedor_nome: vendedor_nome ?? null,
        loja: loja ?? null,
        full_name: full_name ?? null,
        active: true,
      })
      .eq("id", invited.user.id);

    if (updateErr) {
      return withCors(new Response(JSON.stringify({ error: updateErr.message }), { status: 400 }));
    }

    return withCors(new Response(JSON.stringify({ ok: true, user_id: invited.user.id }), {
      headers: { "Content-Type": "application/json" },
    }));
  } catch (e) {
    return withCors(new Response(JSON.stringify({ error: String(e) }), { status: 500 }));
  }
});
