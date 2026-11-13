@{
    IncludeRules = @(
        'PSAvoidReservedWordsAsFunctionNames'
        'PSAvoidUsingBrokenHashAlgorithms'
        'PSAvoidUsingCmdletAliases'
        'PSAvoidUsingDeprecatedManifestFields'
        'PSAvoidUsingEmptyCatchBlock'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSMisleadingBacktick'
        'PSPossibleIncorrectComparisonWithNull'
        'PSPossibleIncorrectUsageOfAssignmentOperator'
        'PSPossibleIncorrectUsageOfRedirectionOperator'
        'PSReservedCmdletChar'
        'PSReservedParams'
        'PSUseCompatibleSyntax'
        'PSUsePSCredentialType'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('5.1')
        }
    }
}
