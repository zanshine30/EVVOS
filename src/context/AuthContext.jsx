import React, { createContext, useState, useEffect, useCallback } from "react";
import AsyncStorage from '@react-native-async-storage/async-storage';
import supabase from "../lib/supabase";
import * as Notifications from 'expo-notifications';

export const AuthContext = createContext();

export function AuthProvider({ children }) {
    const [user, setUser] = useState(null);
    const [session, setSession] = useState(null);
    const [profile, setProfile] = useState(null);
    const [badge, setBadge] = useState(null);
    const [loading, setLoading] = useState(true);
    const [rememberMe, setRememberMe] = useState(false);

    // Load session + profile
    useEffect(() => {
        let mounted = true;

        const init = async () => {
            try {
                const { data } = await supabase.auth.getSession();
                const sessionObj = data?.session ?? null;
                if (!mounted) return;

                setSession(sessionObj);
                setUser(sessionObj?.user ?? null);

                // read profile (prefer RPC 'get_my_profile')
                if (sessionObj?.user?.id) {
                    try {
                        const { data: rpcData, error: rpcErr } = await supabase.rpc("get_my_profile");
                        if (!rpcErr && Array.isArray(rpcData) && rpcData.length > 0) {
                            setProfile(rpcData[0]);
                        } else {
                            // fallback: select from users table
                            const { data: p, error: pErr } = await supabase
                                .from("users")
                                .select("display_name, role, first_name, last_name, badge")
                                .eq("auth_user_id", sessionObj.user.id)
                                .maybeSingle();
                            if (!pErr && p) {
                                setProfile(p);
                                setBadge(p.badge);
                            } else {
                                setProfile(null);
                                setBadge(null);
                            }
                        }
                    } catch (err) {
                        console.warn("Profile load failed:", err);
                        setProfile(null);
                        setBadge(null);
                    }
                } else {
                    // Not signed in: check storage for remember me
                    const savedEmail = await AsyncStorage.getItem("evvos_remember_email");
                    if (savedEmail) setRememberMe(true);
                }

                // Register for push notifications
                if (sessionObj?.user?.id) {
                    registerForPushNotificationsAsync(sessionObj.user.id);
                }
            } catch (err) {
                console.error("Failed to initialize auth:", err);
            } finally {
                if (mounted) setLoading(false);
            }
        };

        init();

        // subscribe to auth changes
        const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
            setSession(session ?? null);
            setUser(session?.user ?? null);

            // when signed in, fetch profile (RPC preferred)
            if (session?.user?.id) {
                (async () => {
                    try {
                        const { data: rpcData, error: rpcErr } = await supabase.rpc("get_my_profile");
                        if (!rpcErr && Array.isArray(rpcData) && rpcData.length > 0) {
                            setProfile(rpcData[0]);
                            setBadge(rpcData[0].badge);
                            registerForPushNotificationsAsync(session.user.id);
                        } else {
                            const { data: p, error: pErr } = await supabase
                                .from("users")
                                .select("display_name, role, first_name, last_name, badge")
                                .eq("auth_user_id", session.user.id)
                                .maybeSingle();
                            if (!pErr) {
                                setProfile(p ?? null);
                                setBadge(p?.badge ?? null);
                                if (p) registerForPushNotificationsAsync(session.user.id);
                            }
                        }
                    } catch (e) {
                        console.warn("Profile refresh failed:", e);
                        setProfile(null);
                        setBadge(null);
                    }
                })();
            } else {
                setProfile(null);
                setBadge(null);
                // Not signed in: check storage for remember me
                (async () => {
                    const savedEmail = await AsyncStorage.getItem("evvos_remember_email");
                    if (savedEmail) setRememberMe(true);
                })();
            }
        });

        return () => {
            mounted = false;
            sub?.subscription?.unsubscribe?.();
        };
    }, []);

    const registerForPushNotificationsAsync = async (userId) => {
        if (!userId) return;
        try {
            const { status } = await Notifications.requestPermissionsAsync();
            if (status !== 'granted') return;
            const token = (await Notifications.getExpoPushTokenAsync()).data;
            await supabase.from('users').update({ push_token: token }).eq('auth_user_id', userId);
        } catch (err) {
            console.warn('Push notification setup failed:', err);
        }
    };

    const login = useCallback(async (email, password, shouldRemember = false) => {
        try {
            const { data: authData, error: authErr } = await supabase.auth.signInWithPassword({ email, password });
            if (authErr) throw authErr;

            setSession(authData.session);
            setUser(authData.user);

            // fetch profile via RPC or fallback
            if (authData.user?.id) {
                try {
                    const { data: rpcData, error: rpcErr } = await supabase.rpc("get_my_profile");
                    if (!rpcErr && Array.isArray(rpcData) && rpcData.length > 0) {
                        setProfile(rpcData[0]);
                        setBadge(rpcData[0].badge);
                    } else {
                        const { data: p } = await supabase
                            .from("users")
                            .select("display_name, role, first_name, last_name, badge")
                            .eq("auth_user_id", authData.user.id)
                            .maybeSingle();
                        setProfile(p ?? null);
                        setBadge(p?.badge ?? null);
                    }
                } catch (err) {
                    console.warn("Profile fetch after login failed:", err);
                    setProfile(null);
                    setBadge(null);
                }
            }

            if (shouldRemember) {
                await AsyncStorage.setItem("evvos_remember_email", email);
                setRememberMe(true);
            } else {
                await AsyncStorage.removeItem("evvos_remember_email");
                setRememberMe(false);
            }
            return { success: true };
        } catch (err) {
            return { success: false, error: err.message || "Login failed" };
        }
    }, []);

    const logout = useCallback(async () => {
        try {
            await supabase.auth.signOut();
            setSession(null);
            setUser(null);
            setProfile(null);
            setBadge(null);
            await AsyncStorage.removeItem("evvos_remember_email");
            setRememberMe(false);
            return { success: true };
        } catch (err) {
            return { success: false, error: err.message || "Logout failed" };
        }
    }, []);

    const loginByBadge = useCallback(async (badgeInput, password) => {
        try {
            // First, find user by badge, role, and status
            const { data: userData, error: userErr } = await supabase
                .from('users')
                .select('email, role, status, display_name, badge')
                .eq('badge', badgeInput)
                .eq('role', 'enforcer')
                .eq('status', 'active')
                .single();

            if (userErr || !userData) {
                return { success: false, error: "Invalid badge number or password." };
            }

            // Now login with email
            const result = await login(userData.email, password);
            if (result.success) {
                setBadge(userData.badge);
            }
            return result;
        } catch (err) {
            return { success: false, error: err.message || "Login failed" };
        }
    }, [login]);

    // convenience fields
    const displayName = (profile?.display_name ?? `${profile?.first_name ?? ""} ${profile?.last_name ?? ""}`.trim()) || (user?.email?.split("@")[0] ?? "User");
    const role = profile?.role ?? "user";

    const avatarInitials = (() => {
        if (profile?.display_name) {
            const parts = profile.display_name.split(" ");
            return (parts[0]?.[0] ?? "U") + (parts[1]?.[0] ?? "");
        }
        if (profile?.first_name) return (profile.first_name[0] ?? "U") + (profile.last_name?.[0] ?? "");
        return (displayName[0] ?? "U").toUpperCase();
    })();

    const value = {
        user,
        session,
        profile,
        badge,
        displayName,
        role,
        avatarInitials,
        loading,
        rememberMe,
        login,
        loginByBadge,
        logout,
        isAuthenticated: !!session,
    };

    return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
    const context = React.useContext(AuthContext);
    if (!context) throw new Error("useAuth must be used within AuthProvider");
    return context;
}