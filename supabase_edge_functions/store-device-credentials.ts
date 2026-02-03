import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  // Handle CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      return new Response(
        JSON.stringify({ error: "Method not allowed" }),
        { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Get device info from request
    const { device_id, device_name, encrypted_ssid, encrypted_password, user_id } = await req.json();

    // Validate required fields
    if (!device_id || !encrypted_ssid || !encrypted_password || !user_id) {
      return new Response(
        JSON.stringify({ 
          error: "Missing required fields: device_id, encrypted_ssid, encrypted_password, user_id" 
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Get Supabase client
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error("Missing Supabase environment variables");
    }

    // Insert device credentials into the database
    const response = await fetch(`${supabaseUrl}/rest/v1/device_credentials`, {
      method: "POST",
      headers: {
        "apikey": supabaseServiceKey,
        "Authorization": `Bearer ${supabaseServiceKey}`,
        "Content-Type": "application/json",
        "Prefer": "return=representation",
      },
      body: JSON.stringify({
        user_id: user_id,
        device_id: device_id,
        device_name: device_name || "EVVOS_0001",
        encrypted_ssid: encrypted_ssid,
        encrypted_password: encrypted_password,
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error("Database insert failed:", errorText);
      throw new Error(`Database insert failed: ${response.status} - ${errorText}`);
    }

    const result = await response.json();
    
    return new Response(
      JSON.stringify({
        success: true,
        message: "Device credentials stored successfully",
        device_id: device_id,
      }),
      { 
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" }
      }
    );

  } catch (error) {
    console.error("Error in store-device-credentials:", error.message);
    return new Response(
      JSON.stringify({
        error: "Failed to store device credentials",
        details: error.message,
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
