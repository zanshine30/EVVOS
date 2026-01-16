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
} from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";


import { clearPaired } from "../utils/deviceStore";
import { useAuth } from "../context/AuthContext";

export default function LoginScreen({ navigation }) {
  const { loginByBadge } = useAuth();
  const [badgeNumber, setBadgeNumber] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);

  const [badgeError, setBadgeError] = useState("");
  const [passError, setPassError] = useState("");

  const handleSignIn = async () => {
    const badgeTrimmed = badgeNumber.trim();
    const passTrimmed = password.trim();

    let hasError = false;

    if (!badgeTrimmed) {
      setBadgeError("Badge number must not be empty.");
      hasError = true;
    } else {
      setBadgeError("");
    }

    if (!passTrimmed) {
      setPassError("Password must not be empty.");
      hasError = true;
    } else {
      setPassError("");
    }

    if (hasError) return;

    try {
      const result = await loginByBadge(badgeTrimmed, passTrimmed);
      if (!result.success) {
        setPassError(result.error);
        return;
      }

      // Successfully logged in
      await clearPaired();

      navigation.reset({
        index: 0,
        routes: [{ name: "DeviceWelcome" }],
      });
    } catch (err) {
      setPassError("An error occurred. Please try again.");
    }
  };

  const handleForgotPassword = () => {
    navigation.navigate("ForgotPassword");
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
        <ScrollView
          contentContainerStyle={styles.scroll}
          keyboardShouldPersistTaps="handled"
        >
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

          <View style={styles.form}>
            <Text style={styles.label}>Badge Number</Text>
            <View style={[styles.inputWrap, badgeError ? styles.inputWrapError : null]}>
              <TextInput
                value={badgeNumber}
                onChangeText={(t) => {
                  setBadgeNumber(t);
                  if (badgeError) setBadgeError("");
                }}
                placeholder="Enter badge number"
                placeholderTextColor="rgba(255,255,255,0.45)"
                style={styles.input}
                autoCapitalize="none"
                autoCorrect={false}
                returnKeyType="next"
              />
            </View>
            {!!badgeError && <Text style={styles.errorText}>{badgeError}</Text>}

            <Text style={[styles.label, { marginTop: 14 }]}>Password</Text>
            <View style={[styles.inputWrap, passError ? styles.inputWrapError : null]}>
              <TextInput
                value={password}
                onChangeText={(t) => {
                  setPassword(t);
                  if (passError) setPassError("");
                }}
                placeholder="Enter password"
                placeholderTextColor="rgba(255,255,255,0.45)"
                style={styles.input}
                secureTextEntry={!showPassword}
                autoCapitalize="none"
                autoCorrect={false}
                returnKeyType="done"
              />

              <TouchableOpacity
                onPress={() => setShowPassword((v) => !v)}
                style={styles.eyeBtn}
                activeOpacity={0.7}
              >
                <Ionicons
                  name={showPassword ? "eye-off" : "eye"}
                  size={20}
                  color="rgba(255,255,255,0.75)"
                />
              </TouchableOpacity>
            </View>
            {!!passError && <Text style={styles.errorText}>{passError}</Text>}

            <TouchableOpacity
              onPress={handleForgotPassword}
              style={styles.forgotWrap}
              activeOpacity={0.7}
            >
              <Text style={styles.forgotText}>Forgot password?</Text>
            </TouchableOpacity>

            <TouchableOpacity
              onPress={handleSignIn}
              style={styles.signInBtn}
              activeOpacity={0.85}
            >
              <Text style={styles.signInText}>Sign In</Text>
            </TouchableOpacity>

            <Text style={styles.footer}>
              Public Safety and Traffic Management Department
            </Text>
          </View>
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

  header: { alignItems: "center", marginBottom: 22 },
  logo: { width: 110, height: 110, marginBottom: 10 },
  title: { color: "white", fontSize: 26, fontWeight: "700", letterSpacing: 1.5, marginTop: 2 },
  subtitle: {
    color: "rgba(255,255,255,0.65)",
    fontSize: 12,
    marginTop: 8,
    textAlign: "center",
    maxWidth: 280,
    lineHeight: 16,
  },

  form: { width: "100%", maxWidth: 420, alignSelf: "center", marginTop: 6 },
  label: { color: "rgba(255,255,255,0.7)", fontSize: 12, marginBottom: 8 },

  inputWrap: {
    backgroundColor: "rgba(255,255,255,0.10)",
    borderRadius: 10,
    height: 48,
    justifyContent: "center",
    paddingHorizontal: 14,
    borderWidth: 1,
    borderColor: "transparent",
  },
  inputWrapError: { borderColor: "rgba(255, 120, 120, 0.95)" },

  input: { color: "white", fontSize: 14, paddingRight: 34 },
  eyeBtn: {
    position: "absolute",
    right: 12,
    height: 48,
    width: 40,
    alignItems: "center",
    justifyContent: "center",
  },

  errorText: { marginTop: 6, color: "rgba(255, 120, 120, 0.95)", fontSize: 11 },

  forgotWrap: { alignSelf: "flex-end", marginTop: 10, marginBottom: 18 },
  forgotText: { color: "rgba(255,255,255,0.65)", fontSize: 12 },

  signInBtn: {
    backgroundColor: "#2E78E6",
    height: 48,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  signInText: { color: "white", fontSize: 14, fontWeight: "600" },

  footer: { marginTop: 18, textAlign: "center", color: "rgba(255,255,255,0.55)", fontSize: 11 },
});