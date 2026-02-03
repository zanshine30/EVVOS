import React, { createContext, useState, useEffect, useCallback } from "react";
import AsyncStorage from '@react-native-async-storage/async-storage';
import supabase from "../lib/supabase";
import * as Notifications from 'expo-notifications';
import messaging from '@react-native-firebase/messaging';

export const AuthContext = createContext();

const SESSION_KEY = 'evvos_session';

export function AuthProvider({ children }) {
    const [user, setUser] = useState(null);
    const [session, setSession] = useState(null);
    const [profile, setProfile] = useState(null);
    const [badge, setBadge] = useState(null);
    const [loading, setLoading] = useState(true);
    const [rememberMe, setRememberMe] = useState(false);
    const [recoveryMode, setRecoveryMode] = useState(false);
    const [isAuthenticated, setIsAuthenticated] = useState(false);
    const [devicePaired, setDevicePaired] = useState(false);
    
    // Flag to skip AsyncStorage removal during initial app load
    const [initComplete, setInitComplete] = useState(false);

    // Load session + profile
    useEffect(() => {
        let mounted = true;
        let initSessionRestored = false; // Track if init successfully restored a session

        const init = async () => {
            try {
                // 1) Try getting the current session from supabase client (with timeout for offline mode)
                let sessionObj = null;
                try {
                    // Add a 5-second timeout for the session check
                    const sessionPromise = supabase.auth.getSession();
                    const timeoutPromise = new Promise((_, reject) =>
                        setTimeout(() => reject(new Error('Session check timeout')), 5000)
                    );
                    const { data } = await Promise.race([sessionPromise, timeoutPromise]);
                    sessionObj = data?.session ?? null;
                    console.log('[Init] supabase.auth.getSession returned:', !!sessionObj);
                } catch (err) {
                    console.warn('[Init] supabase.auth.getSession failed (likely offline):', err.message);
                    sessionObj = null;
                }

                // 2) If supabase didn't return a session, fallback to AsyncStorage stored session
                if (!sessionObj) {
                    const storedSession = await AsyncStorage.getItem(SESSION_KEY);
                    console.log('[Init] Found storedSession in AsyncStorage:', !!storedSession);
                    if (storedSession) {
                        try {
                            const parsed = JSON.parse(storedSession);
                            // restore supabase client with tokens (so onAuthStateChange will fire normally)
                            if (parsed?.access_token || parsed?.refresh_token) {
                                try {
                                    await supabase.auth.setSession({
                                        access_token: parsed.access_token,
                                        refresh_token: parsed.refresh_token,
                                    });
                                    // Ideally supabase.auth.setSession triggers onAuthStateChange;
                                    // but still assign sessionObj here so we can continue initialization now.
                                    sessionObj = parsed;
                                    initSessionRestored = true; // Mark that we restored a session
                                    console.log('[Init] ✅ Restored session into supabase client from AsyncStorage.');
                                } catch (setErr) {
                                    console.warn('[Init] ❌ supabase.auth.setSession failed:', setErr);
                                    // still use parsed locally so UI can consider user signed in if tokens are valid server-side
                                    sessionObj = parsed;
                                    initSessionRestored = true;
                                }
                            } else {
                                console.warn('[Init] parsed stored session lacked tokens.');
                            }
                        } catch (e) {
                            console.warn('[Init] Failed to parse stored session:', e);
                            await AsyncStorage.removeItem(SESSION_KEY);
                        }
                    } else {
                        console.log('[Init] ❌ No stored session in AsyncStorage');
                        // no stored session: ensure Supabase is signed out server-side
                        try {
                            await supabase.auth.signOut();
                            console.log('[Init] Signed out from Supabase.');
                        } catch (e) {
                            console.warn('[Init] signOut failed during init:', e);
                        }
                    }
                } else {
                    // Session was found from supabase.auth.getSession
                    initSessionRestored = true;
                }

                // 3) If we have a session object (from supabase.getSession or storage), set local state
                if (sessionObj?.user?.id) {
                    if (!mounted) return;
                    console.log('[Init] ✅ Session found - setting user as authenticated');
                    console.log('[Init] User ID:', sessionObj.user.id);
                    setSession(sessionObj);
                    setUser(sessionObj.user ?? null);
                    setIsAuthenticated(true);
                    console.log('[Init] ✅ isAuthenticated set to true');
                    console.log('[Init] set session & user from sessionObj:', sessionObj.user.id);

                    // read profile (prefer RPC 'get_my_profile')
                    try {
                        console.log('[Init] Fetching profile for user:', sessionObj.user.id);
                        // Add timeout for profile fetch (offline mode)
                        const profilePromise = supabase.rpc("get_my_profile");
                        const timeoutPromise = new Promise((_, reject) =>
                            setTimeout(() => reject(new Error('Profile fetch timeout')), 5000)
                        );
                        const { data: rpcData, error: rpcErr } = await Promise.race([profilePromise, timeoutPromise]);
                        
                        if (!rpcErr && Array.isArray(rpcData) && rpcData.length > 0) {
                            if (mounted) {
                                setProfile(rpcData[0]);
                                setBadge(rpcData[0].badge);
                                console.log('[Init] ✅ Profile loaded from RPC');
                            }
                        } else {
                            // fallback: select from users table
                            const fallbackPromise = supabase
                                .from("users")
                                .select("display_name, role, first_name, last_name, badge")
                                .eq("auth_user_id", sessionObj.user.id)
                                .maybeSingle();
                            const fallbackTimeoutPromise = new Promise((_, reject) =>
                                setTimeout(() => reject(new Error('Fallback profile fetch timeout')), 5000)
                            );
                            const { data: p, error: pErr } = await Promise.race([fallbackPromise, fallbackTimeoutPromise]);
                            
                            if (!pErr && p && mounted) {
                                setProfile(p);
                                setBadge(p.badge);
                                console.log('[Init] ✅ Profile loaded from users table');
                            } else if (mounted) {
                                console.warn('[Init] No profile found for user (may be offline)');
                                setProfile(null);
                                setBadge(null);
                            }
                        }
                    } catch (err) {
                        console.warn("Profile load failed (likely offline):", err.message);
                        if (mounted) {
                            setProfile(null);
                            setBadge(null);
                        }
                    }

                    // Check if device is already paired
                    try {
                        console.log('[Init] Checking for paired device...');
                        // Add timeout for device check (offline mode)
                        const devicePromise = supabase
                            .from("device_credentials")
                            .select("id, device_name")
                            .eq("user_id", sessionObj.user.id)
                            .maybeSingle();
                        const deviceTimeoutPromise = new Promise((_, reject) =>
                            setTimeout(() => reject(new Error('Device check timeout')), 5000)
                        );
                        const { data: deviceCreds, error: deviceErr } = await Promise.race([devicePromise, deviceTimeoutPromise]);
                        
                        if (!deviceErr && deviceCreds && mounted) {
                            console.log('[Init] ✅ Device already paired:', deviceCreds.device_name);
                            setDevicePaired(true);
                        } else if (mounted) {
                            console.log('[Init] No paired device found (may be offline)');
                            setDevicePaired(false);
                        }
                    } catch (err) {
                        console.warn('[Init] Device check failed:', err);
                        if (mounted) {
                            setDevicePaired(false);
                        }
                    }

                    // register for push notifications
                    registerForPushNotificationsAsync(sessionObj.user.id);
                } else {
                    console.log('[Init] ❌ No session found - user is not authenticated');
                    console.log('[Init] ❌ isAuthenticated set to false');
                    setIsAuthenticated(false);
                    // Not signed in: check storage for remember me
                    const savedEmail = await AsyncStorage.getItem("evvos_remember_email");
                    if (mounted) {
                        if (savedEmail) setRememberMe(true);
                        setIsAuthenticated(false);
                    }
                }
            } catch (err) {
                console.error("Failed to initialize auth:", err);
                // If offline, still allow user to proceed with cached session if available
                if (mounted) {
                    setIsAuthenticated(false);
                    console.log('[Init] ❌ Init error (possibly offline) - allowing offline mode');
                }
            } finally {
                // Mark init as complete so onAuthStateChange knows to remove stored sessions on logout
                if (mounted) {
                    setInitComplete(true);
                }
                
                // Always set loading to false after init completes
                // By this point, isAuthenticated should be set correctly
                if (mounted) {
                    // Add a small delay to ensure all state updates are processed
                    setTimeout(() => {
                        if (mounted) {
                            setLoading(false);
                            console.log('[Init] Loading complete');
                        }
                    }, 100);
                }
            }
        };

        init();

        // subscribe to auth changes
        const { data: sub } = supabase.auth.onAuthStateChange(async (event, newSession) => {
            try {
                console.log('Auth state change:', event, newSession?.user?.id);
                // normalize: some versions return session object directly, some nested under data
                const sess = newSession ?? null;
                setSession(sess);
                setUser(sess?.user ?? null);
                setIsAuthenticated(!!sess?.user?.id);

                // Store or remove session in AsyncStorage
                // IMPORTANT: Only remove if init is complete to avoid clearing stored session on app startup
                if (sess) {
                    try {
                        await AsyncStorage.setItem(SESSION_KEY, JSON.stringify(sess));
                        console.log('[Auth Change] Stored session in AsyncStorage for user:', sess.user?.id);
                    } catch (e) {
                        console.warn('[Auth Change] Failed to write session to AsyncStorage:', e);
                    }
                } else {
                    // Only remove from storage if init is complete (user intentionally logged out)
                    // Don't remove during initial app startup when Supabase reports no session yet
                    if (initComplete) {
                        try {
                            await AsyncStorage.removeItem(SESSION_KEY);
                            console.log('[Auth Change] Removed session from AsyncStorage (intentional logout)');
                        } catch (e) {
                            console.warn('[Auth Change] Failed to remove session from AsyncStorage:', e);
                        }
                    } else {
                        console.log('[Auth Change] Skipping AsyncStorage removal during init (waiting for session restoration)');
                    }
                }

                if (event === 'PASSWORD_RECOVERY') {
                    setRecoveryMode(true);
                } else {
                    setRecoveryMode(false);
                }

                // when signed in, fetch profile (RPC preferred)
                if (sess?.user?.id) {
                    (async () => {
                        try {
                            const { data: rpcData, error: rpcErr } = await supabase.rpc("get_my_profile");
                            if (!rpcErr && Array.isArray(rpcData) && rpcData.length > 0) {
                                setProfile(rpcData[0]);
                                setBadge(rpcData[0].badge);
                                registerForPushNotificationsAsync(sess.user.id);
                            } else {
                                const { data: p, error: pErr } = await supabase
                                    .from("users")
                                    .select("display_name, role, first_name, last_name, badge")
                                    .eq("auth_user_id", sess.user.id)
                                    .maybeSingle();
                                if (!pErr) {
                                    setProfile(p ?? null);
                                    setBadge(p?.badge ?? null);
                                    if (p) registerForPushNotificationsAsync(sess.user.id);
                                }
                            }
                            
                            // Check for paired device
                            const { data: deviceCreds } = await supabase
                                .from("device_credentials")
                                .select("id, device_name")
                                .eq("user_id", sess.user.id)
                                .maybeSingle();
                            
                            if (deviceCreds) {
                                console.log('[Auth Change] Device already paired:', deviceCreds.device_name);
                                setDevicePaired(true);
                            } else {
                                console.log('[Auth Change] No paired device found');
                                setDevicePaired(false);
                            }
                        } catch (e) {
                            console.warn("Profile/device refresh failed:", e);
                            setProfile(null);
                            setBadge(null);
                            setDevicePaired(false);
                        }
                    })();
                } else {
                    setProfile(null);
                    setBadge(null);
                    setDevicePaired(false);
                    // Not signed in: check storage for remember me
                    (async () => {
                        const savedEmail = await AsyncStorage.getItem("evvos_remember_email");
                        if (savedEmail) setRememberMe(true);
                    })();
                }
            } catch (e) {
                console.warn('onAuthStateChange handler error:', e);
            }
            // DON'T set loading to false here - let the init function control that
            // This prevents LoadingScreen from navigating before isAuthenticated is set
        });

        return () => {
            mounted = false;
            try {
                sub?.subscription?.unsubscribe?.();
            } catch (e) {
                // older SDK shapes may differ
                try {
                    sub?.unsubscribe?.();
                } catch (ignore) { }
            }
        };
    }, []);

    const registerForPushNotificationsAsync = async (userId) => {
        if (!userId) {
            console.warn('No userId provided for push notifications');
            return;
        }
        console.log('=== Starting FCM Registration ===');
        console.log('User ID:', userId);
        
        try {
            // Step 1: Request Expo Notifications permission
            console.log('[Step 1] Requesting Expo Notifications permission...');
            const { status } = await Notifications.requestPermissionsAsync();
            console.log('[Step 1] Notification permission status:', status);
            
            if (status !== 'granted') {
                console.warn('[Step 1] ❌ Expo permission NOT granted. Status:', status);
                return;
            }
            console.log('[Step 1] ✅ Expo permission granted');

            // Step 2: Request Firebase Messaging permission
            console.log('[Step 2] Requesting Firebase Messaging permission...');
            const authStatus = await messaging().requestPermission();
            console.log('[Step 2] Firebase auth status:', authStatus);
            
            const enabled =
                authStatus === messaging.AuthorizationStatus.AUTHORIZED ||
                authStatus === messaging.AuthorizationStatus.PROVISIONAL;
            
            if (!enabled) {
                console.warn('[Step 2] ❌ Firebase permission NOT granted. Status:', authStatus);
                return;
            }
            console.log('[Step 2] ✅ Firebase permission granted');

            // Step 3: Get FCM token
            console.log('[Step 3] Retrieving FCM token...');
            const fcmToken = await messaging().getToken();
            console.log('[Step 3] FCM Token retrieved:', fcmToken ? `${fcmToken.substring(0, 20)}...` : 'EMPTY');
            
            if (!fcmToken) {
                console.warn('[Step 3] ❌ FCM token is empty or undefined');
                return;
            }
            console.log('[Step 3] ✅ FCM token obtained');

            // Step 4: Save to Supabase
            console.log('[Step 4] Saving FCM token to Supabase...');
            console.log('[Step 4] Update query: UPDATE users SET push_token=? WHERE auth_user_id=?');
            
            const { data, error } = await supabase
                .from('users')
                .update({ push_token: fcmToken })
                .eq('auth_user_id', userId)
                .select();
            
            if (error) {
                console.error('[Step 4] ❌ Database error:', {
                    message: error.message,
                    code: error.code,
                    details: error.details,
                    hint: error.hint
                });
                return;
            }
            
            if (!data || data.length === 0) {
                console.warn('[Step 4] ⚠️  No rows updated. User might not exist in database');
                return;
            }
            
            console.log('[Step 4] ✅ Push token saved successfully');
            console.log('[Step 4] Updated records:', data.length);
            console.log('=== FCM Registration Complete ===');
            
        } catch (err) {
            console.error('=== FCM Registration Failed ===');
            console.error('Error:', {
                message: err?.message,
                code: err?.code,
                stack: err?.stack
            });
        }
    };

    const login = useCallback(async (email, password, shouldRemember = false) => {
        try {
            const { data: authData, error: authErr } = await supabase.auth.signInWithPassword({ email, password });
            if (authErr) throw authErr;

            const sess = authData.session;
            setSession(sess);
            setUser(authData.user);

            // Ensure we persist session immediately
            try {
                if (sess) {
                    await AsyncStorage.setItem(SESSION_KEY, JSON.stringify(sess));
                    console.log('[Login] Persisted session to AsyncStorage for user:', authData.user?.id);
                }
            } catch (e) {
                console.warn('[Login] Failed to persist session:', e);
            }

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
            setDevicePaired(false);
            await AsyncStorage.removeItem(SESSION_KEY);
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

    const resetPasswordForEmail = useCallback(async (email) => {
        try {
            const { error } = await supabase.auth.resetPasswordForEmail(email, {
                redirectTo: 'evvos://reset-password',
            });
            if (error) throw error;
            return { success: true };
        } catch (err) {
            return { success: false, error: err.message };
        }
    }, []);

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
        recoveryMode,
        isAuthenticated,
        devicePaired,
        login,
        loginByBadge,
        logout,
        resetPasswordForEmail,
    };

    return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
    const context = React.useContext(AuthContext);
    if (!context) throw new Error("useAuth must be used within AuthProvider");
    return context;
}
