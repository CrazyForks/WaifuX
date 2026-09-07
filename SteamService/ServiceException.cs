//
//  WaifuX Steam service.
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

namespace WaifuXSteamService;

internal sealed class ServiceException : Exception
{
    public string Code { get; }

    public ServiceException(string code, string message) : base(message)
    {
        Code = code;
    }
}
