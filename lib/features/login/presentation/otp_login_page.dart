import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_base_app/core/navigation/app_router.dart';
import 'package:flutter_base_app/core/utils/app_utils.dart';
import 'package:go_router/go_router.dart';

class OtpLoginPage extends StatefulWidget {
  final String? initialPhone;
  const OtpLoginPage({super.key, this.initialPhone});

  @override
  State<OtpLoginPage> createState() => _OtpLoginPageState();
}

class _OtpLoginPageState extends State<OtpLoginPage> {
  final _phoneFormKey = GlobalKey<FormState>();
  final _otpFormKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();

  bool _otpSent = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialPhone != null && widget.initialPhone!.isNotEmpty) {
      _phoneController.text = widget.initialPhone!;
      _otpSent = true;
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _handleSendOtp() async {
    if (!_phoneFormKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    // Simulate API call
    await Future.delayed(const Duration(seconds: 2));

    if (mounted) {
      setState(() {
        _isLoading = false;
        _otpSent = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('OTP sent to your mobile number.')),
      );
    }
  }

  Future<void> _handleVerifyOtp() async {
    if (!_otpFormKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    // Simulate API call
    await Future.delayed(const Duration(seconds: 2));

    if (mounted) {
      setState(() => _isLoading = false);
      // Navigate to Home on success
      context.go(AppRoutes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Login with OTP')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _otpSent
                ? _buildOtpForm(colorScheme)
                : _buildPhoneForm(colorScheme),
          ),
        ),
      ),
    );
  }

  Widget _buildPhoneForm(ColorScheme colorScheme) {
    return Form(
      key: _phoneFormKey,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.phone_android_rounded,
            size: 64,
            color: colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Welcome',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Enter your mobile number to receive a temporary login code.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // Phone Field
          TextFormField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            maxLength: AppConstants.mobileNumberLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Mobile Number',
              prefixIcon: Icon(Icons.phone),
              prefixText: '+91 ',
              counterText: '',
            ),
            validator: (value) {
              if (!value.isValidMobile) {
                return 'Enter a valid ${AppConstants.mobileNumberLength}-digit mobile number';
              }
              return null;
            },
          ),
          const SizedBox(height: 24),

          // Send Button
          FilledButton(
            onPressed: _isLoading ? null : _handleSendOtp,
            child: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send OTP'),
          ),
        ],
      ),
    );
  }

  Widget _buildOtpForm(ColorScheme colorScheme) {
    return Form(
      key: _otpFormKey,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.message_rounded, size: 64, color: colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'Verify Code',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Enter the 4-digit code sent to\n+91 ${_phoneController.text}',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // OTP Field
          TextFormField(
            controller: _otpController,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(
              letterSpacing: 16,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            maxLength: 4,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              hintText: '••••',
              counterText: '',
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Code is required';
              }
              if (value.length != 4) {
                return 'Enter the full 4-digit code';
              }
              return null;
            },
          ),
          const SizedBox(height: 24),

          // Verify Button
          FilledButton(
            onPressed: _isLoading ? null : _handleVerifyOtp,
            child: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Verify & Login'),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              setState(() {
                _otpSent = false;
                _otpController.clear();
              });
            },
            child: const Text('Use a different number'),
          ),
        ],
      ),
    );
  }
}
