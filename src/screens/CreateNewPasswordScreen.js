import React, { useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  Image,
  TextInput,
  TouchableOpacity,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  Alert,
  ActivityIndicator,
} from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import supabase from "../lib/supabase";

export default function CreateNewPasswordScreen({ navigation, route }) {
  const { email, sentTime } = route.params || {};
  const [resetToken, setResetToken] = useState("");
  const [badge, setBadge] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showNew, setShowNew] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [loading, setLoading] = useState(false);
  const [timeRemaining, setTimeRemaining] = useState(900); // 15 minutes in seconds
  const [otpExpired, setOtpExpired] = useState(false);

  // Timer effect
  React.useEffect(() => {
    const initialTime = sentTime ? Math.floor((900000 - (new Date().getTime() - sentTime)) / 1000) : 900;
    setTimeRemaining(Math.max(0, initialTime));

    const interval = setInterval(() => {
      setTimeRemaining((prev) => {
        if (prev <= 1) {
          setOtpExpired(true);
          clearInterval(interval);
          return 0;
        }
        return prev - 1;
      });
    }, 1000);

    return () => clearInterval(interval);
  }, [sentTime]);

  const handleResendOtp = async () => {
    if (!email) return;
    setLoading(true);
    try {
      const { error } = await supabase.auth.signInWithOtp({ email });
      if (error) throw error;
      setOtpExpired(false);
      setTimeRemaining(900);
      setResetToken("");
      Alert.alert("OTP Resent", "A new OTP has been sent to your email.");
    } catch (err) {
      Alert.alert("Error", err.message || "Failed to resend OTP.");
    } finally {
      setLoading(false);
    }
  };

  const handleConfirm = async () => {
    if (!email) {
      Alert.alert("Error", "Email address not found. Please try the forgot password process again.");
      return;
    }
    if (otpExpired) {
      Alert.alert("OTP Expired", "Your OTP has expired. Please request a new one.");
      return;
    }
    const tokenTrimmed = resetToken.trim();
    const badgeTrimmed = badge.trim();
    
    if (!tokenTrimmed) {
      Alert.alert("Missing Token", "Please enter the 8-digit OTP.");
      return;
    }
    if (!badgeTrimmed) {
      Alert.alert("Missing Badge", "Please enter your badge number.");
      return;
    }
    if (!/^\d+$/.test(badgeTrimmed)) {
      Alert.alert("Invalid Badge", "Badge number must contain only digits.");
      return;
    }
    if (!newPassword) {
      Alert.alert("Missing Password", "Please enter a new password.");
      return;
    }
    if (!confirmPassword) {
      Alert.alert("Missing Confirmation", "Please confirm your password.");
      return;
    }
    const passwordRegex = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{8,16}$/;
    if (!passwordRegex.test(newPassword)) {
      Alert.alert("Weak Password", "Password must be 8-16 characters with at least one lowercase, one uppercase, one digit, and one special character.");
      return;
    }
    if (newPassword !== confirmPassword) {
      Alert.alert("Mismatch", "Passwords do not match.");
      return;
    }

    setLoading(true);
    try {
      console.log('Verifying token for email:', email, 'token:', tokenTrimmed);
      // Verify the OTP
      const { data: verifyData, error: verifyError } = await supabase.auth.verifyOtp({
        email: email,
        token: tokenTrimmed,
        type: 'magiclink'
      });

      console.log('Verify result:', verifyData, verifyError);

      if (verifyError || !verifyData?.user) {
        Alert.alert("Invalid OTP", "The OTP is invalid or expired.");
        setLoading(false);
        return;
      }

      // Verify badge belongs to this email
      const { data: userData, error: checkErr } = await supabase
        .from('users')
        .select('badge')
        .eq('email', email)
        .eq('badge', badgeTrimmed)
        .eq('role', 'enforcer')
        .eq('status', 'active')
        .single();

      if (checkErr || !userData) {
        Alert.alert("Invalid Badge", "The badge number does not match this email address.");
        // Sign out the temporary session
        await supabase.auth.signOut();
        setLoading(false);
        return;
      }

      // Update password
      const { error: updateErr } = await supabase.auth.updateUser({ password: newPassword });
      if (updateErr) throw updateErr;

      // Sign out after successful password update
      await supabase.auth.signOut();

      Alert.alert("Success", "Your password has been updated.", [
        {
          text: "OK",
          onPress: () => navigation.reset({ index: 0, routes: [{ name: "Login" }] }),
        },
      ]);
    } catch (err) {
      Alert.alert("Error", err.message || "Failed to update password. Please try again.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === "ios" ? "padding" : undefined}
      >
        <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
         
          <View style={styles.header}>
            <Image
              source={require("../../assets/logo.png")}
              style={styles.logo}
              resizeMode="contain"
            />
            <Text style={styles.title}>E.V.V.O.S.</Text>
            <Text style={styles.subtitle}>
              Enforcer Voice-activated Video Observation System
            </Text>
          </View>

        
          <View style={styles.card}>
            <View style={styles.cardTop}>
              <TouchableOpacity
                onPress={() => navigation.goBack()}
                style={styles.backBtn}
                activeOpacity={0.7}
              >
                <Ionicons name="chevron-back" size={22} color="rgba(255,255,255,0.85)" />
              </TouchableOpacity>

              <Text style={styles.cardTitle}>Reset Password</Text>
              <View style={{ width: 36 }} />
            </View>

            <View style={styles.cardBody}>
              <Text style={styles.info}>Enter the 8-digit OTP from your email, verify your badge (digits only), and set a new password (8-16 characters with uppercase, lowercase, digit, and special character).</Text>

              <View style={styles.otpHeader}>
                <Text style={[styles.label, { marginTop: 0, marginBottom: 0 }]}>OTP</Text>
                <Text style={[styles.timerText, otpExpired && styles.timerExpired]}>
                  {otpExpired ? "Expired" : `${Math.floor(timeRemaining / 60)}:${String(timeRemaining % 60).padStart(2, "0")}`}
                </Text>
              </View>
              <View style={[styles.inputWrap, otpExpired && styles.inputWrapError]}>
                <TextInput
                  value={resetToken}
                  onChangeText={setResetToken}
                  placeholder="Enter 8-digit OTP"
                  placeholderTextColor="rgba(255,255,255,0.45)"
                  style={styles.input}
                  keyboardType="numeric"
                  maxLength={8}
                  autoCapitalize="none"
                  autoCorrect={false}
                  editable={!otpExpired}
                />
              </View>
              {otpExpired && (
                <TouchableOpacity onPress={handleResendOtp} style={styles.resendBtn} activeOpacity={0.85} disabled={loading}>
                  <Text style={styles.resendText}>{loading ? "Resending..." : "Resend OTP"}</Text>
                </TouchableOpacity>
              )}

              <Text style={[styles.label, { marginTop: 12 }]}>Badge Number</Text>
              <View style={styles.inputWrap}>
                <TextInput
                  value={badge}
                  onChangeText={setBadge}
                  placeholder="Enter badge number"
                  placeholderTextColor="rgba(255,255,255,0.45)"
                  style={styles.input}
                  keyboardType="numeric"
                  autoCapitalize="none"
                  autoCorrect={false}
                />
              </View>

              <Text style={[styles.label, { marginTop: 12 }]}>New password</Text>
              <View style={styles.inputWrap}>
                <TextInput
                  value={newPassword}
                  onChangeText={setNewPassword}
                  placeholder="Enter password"
                  placeholderTextColor="rgba(255,255,255,0.45)"
                  style={styles.input}
                  secureTextEntry={!showNew}
                  autoCapitalize="none"
                  autoCorrect={false}
                />
                <TouchableOpacity
                  onPress={() => setShowNew((v) => !v)}
                  style={styles.eyeBtn}
                  activeOpacity={0.7}
                >
                  <Ionicons
                    name={showNew ? "eye" : "eye-off"}
                    size={20}
                    color="rgba(255,255,255,0.75)"
                  />
                </TouchableOpacity>
              </View>

              <Text style={[styles.label, { marginTop: 12 }]}>Confirm password</Text>
              <View style={styles.inputWrap}>
                <TextInput
                  value={confirmPassword}
                  onChangeText={setConfirmPassword}
                  placeholder="Confirm password"
                  placeholderTextColor="rgba(255,255,255,0.45)"
                  style={styles.input}
                  secureTextEntry={!showConfirm}
                  autoCapitalize="none"
                  autoCorrect={false}
                />
                <TouchableOpacity
                  onPress={() => setShowConfirm((v) => !v)}
                  style={styles.eyeBtn}
                  activeOpacity={0.7}
                >
                  <Ionicons
                    name={showConfirm ? "eye" : "eye-off"}
                    size={20}
                    color="rgba(255,255,255,0.75)"
                  />
                </TouchableOpacity>
              </View>

              <TouchableOpacity onPress={handleConfirm} style={styles.primaryBtn} activeOpacity={0.85} disabled={loading}>
                {loading ? (
                  <ActivityIndicator size="small" color="white" />
                ) : (
                  <Text style={styles.primaryText}>Confirm</Text>
                )}
              </TouchableOpacity>
            </View>
          </View>

          <Text style={styles.footer}>
            Public Safety and Traffic Management Department
          </Text>
        </ScrollView>
      </KeyboardAvoidingView>
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  gradient: { flex: 1 },
  scroll: {
    flexGrow: 1,
    justifyContent: "center",
    paddingHorizontal: 22,
    paddingVertical: 28,
  },

  header: { alignItems: "center", marginBottom: 18 },
  logo: { width: 105, height: 105, marginBottom: 10 },
  title: {
    color: "white",
    fontSize: 26,
    fontWeight: "700",
    letterSpacing: 1.5,
    marginTop: 2,
  },
  subtitle: {
    color: "rgba(255,255,255,0.65)",
    fontSize: 12,
    marginTop: 8,
    textAlign: "center",
    maxWidth: 280,
    lineHeight: 16,
  },

  card: {
    backgroundColor: "rgba(0,0,0,0.15)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.18)",
    overflow: "hidden",
  },
  cardTop: {
    height: 44,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderBottomWidth: 1,
    borderBottomColor: "rgba(255,255,255,0.18)",
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 8,
  },
  backBtn: {
    width: 36,
    height: 36,
    alignItems: "center",
    justifyContent: "center",
  },
  cardTitle: { color: "rgba(255,255,255,0.9)", fontSize: 13, fontWeight: "600" },

  cardBody: { padding: 14 },

  info: { color: "rgba(255,255,255,0.65)", fontSize: 11, lineHeight: 15 },

  label: { color: "rgba(255,255,255,0.75)", fontSize: 12, marginBottom: 8 },

  inputWrap: {
    backgroundColor: "rgba(255,255,255,0.10)",
    borderRadius: 10,
    height: 46,
    justifyContent: "center",
    paddingHorizontal: 14,
  },
  input: { color: "white", fontSize: 14, paddingRight: 34 },
  eyeBtn: {
    position: "absolute",
    right: 10,
    height: 46,
    width: 40,
    alignItems: "center",
    justifyContent: "center",
  },

  primaryBtn: {
    marginTop: 14,
    backgroundColor: "#2E78E6",
    height: 46,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  primaryText: { color: "white", fontSize: 13, fontWeight: "600" },

  footer: {
    marginTop: 16,
    textAlign: "center",
    color: "rgba(255,255,255,0.55)",
    fontSize: 11,
  },
  otpHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginTop: 10,
    marginBottom: 8,
  },
  timerText: {
    color: "rgba(255,255,255,0.75)",
    fontSize: 12,
    fontWeight: "600",
  },
  timerExpired: {
    color: "rgba(255, 120, 120, 0.95)",
  },
  inputWrapError: {
    borderWidth: 1,
    borderColor: "rgba(255, 120, 120, 0.5)",
  },
  resendBtn: {
    marginTop: 10,
    backgroundColor: "rgba(255, 120, 120, 0.2)",
    paddingVertical: 10,
    borderRadius: 8,
    alignItems: "center",
    borderWidth: 1,
    borderColor: "rgba(255, 120, 120, 0.4)",
  },
  resendText: {
    color: "rgba(255, 120, 120, 0.95)",
    fontSize: 12,
    fontWeight: "600",
  },
});
