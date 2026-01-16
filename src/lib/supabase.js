import { createClient } from "@supabase/supabase-js";

const supabaseUrl = "https://zekbonbxwccgsfagrrph.supabase.co";
const supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpla2JvbmJ4d2NjZ3NmYWdycnBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjgzOTQyOTUsImV4cCI6MjA4Mzk3MDI5NX0.0ss5U-uXryhWGf89ucndqNK8-Bzj_GRZ-4-Xap6ytHg";

const supabase = createClient(supabaseUrl, supabaseAnonKey);

export default supabase;
